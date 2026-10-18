package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// Installing makes the daemon a per-user login service — launchd on macOS, a
// systemd user unit on Linux (WSL included, when systemd is on) — so it runs
// as the user, with their files and their shell, and comes back after a
// reboot. Not a system service: it would run as root, which is more reach than
// anything the agent asked for.

const (
	launchdLabel = "cloud.loom.node"
	systemdUnit  = "loom-node.service"
)

func runInstall(args []string) int {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	origin := fs.String("url", "", "loom's address, e.g. https://loom.example.com")
	token := fs.String("token", "", "this device's token, from the install script")
	shell := fs.String("shell", os.Getenv("SHELL"), "the shell commands run in")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *origin == "" || *token == "" {
		fmt.Fprintln(os.Stderr, "usage: loom-node install --url URL --token TOKEN [--shell SHELL]\n"+
			"(the install command in loom's Devices dialog does this for you)")
		return 2
	}

	cfg := config{URL: strings.TrimRight(*origin, "/"), Token: *token, Shell: *shell}
	if err := writeConfig(cfg); err != nil {
		return die("%v", err)
	}
	fmt.Println("wrote", configPath())

	exe, err := os.Executable()
	if err == nil {
		exe, err = filepath.EvalSymlinks(exe)
	}
	if err != nil {
		return die("cannot locate this binary: %v", err)
	}

	switch runtime.GOOS {
	case "darwin":
		err = installLaunchd(exe)
	case "linux":
		err = installSystemd(exe)
	default:
		err = fmt.Errorf("%s is not supported", runtime.GOOS)
	}
	if err != nil {
		return die("%v", err)
	}

	fmt.Println("loom-node is running; the device shows a green dot under Devices in loom once it connects")
	fmt.Println("log of what loom ran here: ~/.local/state/loom-node/log")
	return 0
}

func writeConfig(cfg config) error {
	path := configPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(cfg, "", "  ")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// ── macOS ───────────────────────────────────────────────────────────────

func plistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", launchdLabel+".plist")
}

func installLaunchd(exe string) error {
	home, _ := os.UserHomeDir()
	logPath := filepath.Join(home, "Library", "Logs", "loom-node.log")
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>%s</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, launchdLabel, exe, logPath, logPath)

	if err := os.MkdirAll(filepath.Dir(plistPath()), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(plistPath(), []byte(plist), 0o644); err != nil {
		return err
	}

	domain := fmt.Sprintf("gui/%d", os.Getuid())
	// Whatever was loaded before, possibly an older binary.
	exec.Command("launchctl", "bootout", domain+"/"+launchdLabel).Run()
	if err := run("launchctl", "bootstrap", domain, plistPath()); err != nil {
		return err
	}
	fmt.Println("installed", plistPath(), "— logs in", logPath)
	return nil
}

// ── Linux ───────────────────────────────────────────────────────────────

func unitPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "systemd", "user", systemdUnit)
}

func installSystemd(exe string) error {
	if exec.Command("systemctl", "--user", "show-environment").Run() != nil {
		return installDetached(exe)
	}

	unit := fmt.Sprintf(`[Unit]
Description=loom-node: lets loom's agents run commands here
After=network-online.target

[Service]
ExecStart=%s daemon
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
`, exe)

	if err := os.MkdirAll(filepath.Dir(unitPath()), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(unitPath(), []byte(unit), 0o644); err != nil {
		return err
	}
	for _, args := range [][]string{
		{"--user", "daemon-reload"},
		{"--user", "enable", systemdUnit},
		// restart, not start: a reinstall must pick up the new binary.
		{"--user", "restart", systemdUnit},
	} {
		if err := run("systemctl", args...); err != nil {
			return err
		}
	}
	fmt.Println("installed", unitPath(), "— logs: journalctl --user -u loom-node")

	// Without lingering, a user unit only runs while the user is logged in.
	if err := run("loginctl", "enable-linger"); err != nil {
		fmt.Println("note: could not enable lingering, so loom-node runs only while you are logged in;",
			"`sudo loginctl enable-linger $USER` fixes that")
	}
	return nil
}

// No systemd (WSL without `systemd=true` in /etc/wsl.conf): start it now, in
// the background, and say plainly that it will not come back by itself.
func installDetached(exe string) error {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".local", "state", "loom-node")
	os.MkdirAll(dir, 0o700)
	logFile, err := os.OpenFile(filepath.Join(dir, "daemon.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()

	exec.Command("pkill", "-x", "loom-node").Run()
	cmd := exec.Command(exe, "daemon")
	cmd.Stdout, cmd.Stderr = logFile, logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	fmt.Println("no systemd user session here, so loom-node was started in the background",
		"and will not survive a restart.")
	fmt.Println("on WSL, add `systemd=true` under [boot] in /etc/wsl.conf, run `wsl --shutdown`,",
		"and run this install again to make it permanent.")
	return nil
}

// ── uninstall ───────────────────────────────────────────────────────────

func runUninstall(args []string) int {
	switch runtime.GOOS {
	case "darwin":
		exec.Command("launchctl", "bootout", fmt.Sprintf("gui/%d/%s", os.Getuid(), launchdLabel)).Run()
		os.Remove(plistPath())
	case "linux":
		exec.Command("systemctl", "--user", "disable", "--now", systemdUnit).Run()
		os.Remove(unitPath())
		exec.Command("systemctl", "--user", "daemon-reload").Run()
	}
	os.Remove(configPath())
	fmt.Println("loom-node stopped and its service and token removed; remove the device in loom too")
	return 0
}
