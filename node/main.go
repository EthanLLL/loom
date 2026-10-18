// loom-node puts the user's own machines within reach of loom's agents.
//
// One binary, two roles:
//
//   - On a device (a Mac, a WSL box): `loom-node daemon` keeps a websocket open
//     to loom and runs what it is sent — commands, file reads and writes.
//     `loom-node install` sets that up as a login service; the install script
//     loom hands out runs it.
//   - On the loom host: `loom-node list | exec | read | write` is what an agent
//     calls from its shell. It asks loom, which relays to the device.
//
// See docs/architecture.md §4.4 in the loom repository.
package main

import (
	"fmt"
	"os"
)

// Set at build time; see the Makefile.
var version = "dev"

const usage = `loom-node — run commands and move files on your own machines from loom

On the loom host (for agents):
  loom-node list
  loom-node exec <device> [--cwd DIR] [--timeout SECONDS] -- <command>
  loom-node read <device> <path> > local-file
  loom-node write <device> <path> < local-file

On a device:
  loom-node daemon                          stay connected to loom (what the service runs)
  loom-node install --url URL --token TOKEN [--shell SHELL]
  loom-node uninstall
  loom-node version
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	args := os.Args[2:]
	var code int

	switch os.Args[1] {
	case "list":
		code = cliList(args)
	case "exec":
		code = cliExec(args)
	case "read":
		code = cliRead(args)
	case "write":
		code = cliWrite(args)
	case "daemon":
		code = runDaemon(args)
	case "install":
		code = runInstall(args)
	case "uninstall":
		code = runUninstall(args)
	case "version", "--version", "-v":
		fmt.Println("loom-node", version)
	case "help", "--help", "-h":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "loom-node: unknown command %q\n\n%s", os.Args[1], usage)
		code = 2
	}

	os.Exit(code)
}
