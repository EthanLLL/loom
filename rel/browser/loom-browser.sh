#!/usr/bin/env bash
# A Chromium that stays up on a virtual display, for the agents to drive over CDP
# (127.0.0.1:9222) and for the user to take over through loom's Browser view
# (x11vnc on 127.0.0.1:5900, bridged by LoomWeb.VncSocket). Its profile keeps
# cookies, so a site the user logged in to once stays logged in.
#
# Everything listens on loopback only. If Chromium exits (someone closed its
# last window), it is started again; if the display or VNC dies, so does this
# script, and systemd restarts the lot.
set -u
DISPLAY_NUM=${LOOM_BROWSER_DISPLAY:-99}
SIZE=${LOOM_BROWSER_SIZE:-1280x800}
PROFILE=${LOOM_BROWSER_PROFILE:-$HOME/.local/share/loom-browser/profile}
export DISPLAY=:$DISPLAY_NUM

# Google Chrome if installed: it updates with apt, plays H.264, and doesn't look
# like a test browser to the sites. Otherwise Playwright's own Chromium, the
# newest one installed, so an upgrade that removes the old build doesn't break this.
chrome=$(command -v google-chrome-stable)
[ -x "$chrome" ] || chrome=$(ls -d "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome 2>/dev/null | sort -V | tail -1)
[ -x "$chrome" ] || { echo "no Google Chrome, nor a Playwright Chromium under ~/.cache/ms-playwright" >&2; exit 1; }

Xvfb "$DISPLAY" -screen 0 "${SIZE}x24" -nolisten tcp &
xvfb=$!
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done

x11vnc -display "$DISPLAY" -localhost -rfbport 5900 -forever -shared -nopw -quiet -noxdamage &
vnc=$!

trap 'kill $xvfb $vnc 2>/dev/null; kill $(jobs -p) 2>/dev/null' EXIT
mkdir -p "$PROFILE"
w=${SIZE%x*}; h=${SIZE#*x}
while kill -0 $xvfb 2>/dev/null && kill -0 $vnc 2>/dev/null; do
  # A clean exit flag, so the next start doesn't offer to "restore pages".
  sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PROFILE/Default/Preferences" 2>/dev/null
  "$chrome" --user-data-dir="$PROFILE" --remote-debugging-port=9222 \
    --no-first-run --no-default-browser-check --disable-gpu \
    --window-position=0,0 --window-size="$w,$h" --start-maximized about:blank &
  wait $!
  sleep 1
done
