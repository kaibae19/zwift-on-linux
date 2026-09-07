#!/usr/bin/env bash
# Launch Zwift under wine.
#
# Flow: start the launcher (it patches/updates), let it start the game via
# RunFromProcess, then close the launcher so its blank window goes away, and
# finally tear down the prefix once the game exits.
#
# The launcher window is blank white/black — normal. WebView2 runs but cannot
# paint into the wine window. Do not log in there; log in inside the game.
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-$HOME/Games/zwift/prefix}"
export WINEDEBUG=-all
# WebView2 is Chromium and needs its sandbox off under wine. Do NOT also pass
# --in-process-gpu: combined with --disable-gpu it kills the browser process
# ("WebView2 process failed - Kind: BrowserProcessExited").
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu"

# Debian/Ubuntu keep wineserver out of PATH.
if ! command -v wineserver >/dev/null 2>&1; then
  for d in /usr/lib/*/wine /usr/lib/wine /usr/lib64/wine /opt/wine*/bin; do
    if [ -x "$d/wineserver" ]; then export PATH="$d:$PATH"; break; fi
  done
fi

ZDIR="$WINEPREFIX/drive_c/Program Files (x86)/Zwift"
[ -d "$ZDIR" ] || { echo "Zwift not found at $ZDIR — run install-zwift-wine.sh first"; exit 1; }
cd "$ZDIR"

# Process detection here has three traps:
#   1. ZwiftApp's comm is "main", NOT "ZwiftApp.exe" (wine names it from the
#      internal thread), so `pgrep -x ZwiftApp.exe` matches NOTHING.
#   2. The launcher's comm IS exe-derived, but Linux truncates comm to 15 chars,
#      giving 'ZwiftLauncher.e'.
#   3. pgrep -f is unusable: `wine RunFromProcess-x64.exe ZwiftLauncher.exe
#      ZwiftApp.exe` carries BOTH names in its own command line.
# Match the FIRST token of args exactly — reliable for both.
proc_is_running() {
  ps -eo args --no-headers 2>/dev/null | awk -v want="$1" '$1==want{f=1} END{exit !f}'
}
launcher_running() { proc_is_running 'ZwiftLauncher.exe'; }
game_running()     { proc_is_running 'ZwiftApp.exe'; }

if ! launcher_running; then
  wine ZwiftLauncher.exe >"${TMPDIR:-/tmp}/zwift-launcher.log" 2>&1 &
  sleep 25
fi

# RunFromProcess starts the game from the launcher's process context and exits
# immediately — it is not the game's parent, so we cannot just wait on it.
wine RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe

# Wait for the game to appear. Generous: login, patching and asset load can be
# slow. If it never shows, leave everything alone and exit quietly rather than
# tearing down a launcher that is still doing something useful.
appeared=0
for _ in $(seq 1 150); do            # up to ~5 min
  if game_running; then appeared=1; break; fi
  sleep 2
done
[ "$appeared" -eq 1 ] || exit 0

# Game is up, so patching is done and the launcher has no further job. Close it
# and the blank window goes away.
#
# This IS safe, contrary to a lot of guides (and an earlier version of this
# script). Tested: SIGTERM to the launcher alone left the game running
# indefinitely — VRAM steady, log still advancing, ZwiftApp simply reparented.
# The game depends on *wineserver*, not on the launcher.
#
# What is NOT safe is Zwift's own CloseLauncher.exe: it matches processes by
# name and kills ZwiftApp too, truncating the in-progress activity .fit. That is
# almost certainly where the "never close the launcher" folklore comes from.
# Kill the launcher PID directly; never use CloseLauncher.exe.
launcher_pid=$(ps -eo pid,args --no-headers 2>/dev/null | awk '$2=="ZwiftLauncher.exe"{print $1; exit}')
[ -n "${launcher_pid:-}" ] && kill -TERM "$launcher_pid" 2>/dev/null || true

# Wait for the game to exit.
while game_running; do sleep 1; done

# Deliberate pause: ZwiftApp flushes the in-progress activity .fit on exit, and
# tearing the prefix down too early truncates it. Do NOT remove this.
sleep 3
wineserver -k >/dev/null 2>&1 || true
