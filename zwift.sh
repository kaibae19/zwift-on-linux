#!/usr/bin/env bash
# Launch Zwift under wine.
#
# Flow: start the launcher (it patches/updates), start the game via
# RunFromProcess, close the launcher, then tear down the prefix when the game
# exits.
#
# ON WINE-STAGING 11.16+ the launcher UI renders properly and you can simply run
# ZwiftLauncher.exe and click Play instead of using this script — that path also
# passes an auth token to the game so it logs in automatically. This script
# exists to give a one-click launch that works on both staging and vanilla wine.
#
# ON VANILLA/DISTRO WINE the launcher window is blank (see README: wine's
# DirectComposition gap). The game still starts via RunFromProcess; log in inside
# the game itself.
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-$HOME/Games/zwift/prefix}"
export WINEDEBUG=-all
# WebView2 is Chromium and needs its sandbox off under wine. Do NOT also pass
# --in-process-gpu: combined with --disable-gpu it kills the browser process
# ("WebView2 process failed - Kind: BrowserProcessExited").
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:---no-sandbox}"

# Prefer wine-staging (renders the launcher); fall back to distro wine.
# Debian/Ubuntu also keep wineserver out of PATH.
if [ -x /opt/wine-staging/bin/wine ]; then
  export PATH="/opt/wine-staging/bin:$PATH"
elif ! command -v wineserver >/dev/null 2>&1; then
  for d in /usr/lib/*/wine /usr/lib/wine /usr/lib64/wine /opt/wine*/bin; do
    if [ -x "$d/wineserver" ]; then export PATH="$d:$PATH"; break; fi
  done
fi

ZDIR="$WINEPREFIX/drive_c/Program Files (x86)/Zwift"
[ -d "$ZDIR" ] || { echo "Zwift not found at $ZDIR — run install-zwift-wine.sh first"; exit 1; }
cd "$ZDIR"

# Process detection is genuinely fiddly here:
#   * ZwiftApp's comm is "main", not ZwiftApp.exe (wine names it from the
#     internal thread), so `pgrep -x ZwiftApp.exe` matches NOTHING.
#   * The launcher's comm is truncated by Linux to 15 chars: 'ZwiftLauncher.e'.
#   * The game appears in TWO forms: bare "ZwiftApp.exe" when started by
#     RunFromProcess, and "C:\Program Files (x86)\Zwift\ZwiftApp.exe --token=..."
#     when started from the launcher's Play button. The path contains spaces, so
#     awk field matching does not work.
#   * `wine RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe` contains both
#     names in its own command line, so a naive substring match false-positives.
# Anchoring the basename at the start of args handles every case.
proc_running() { ps -eo args --no-headers 2>/dev/null | grep -qE "$1"; }
launcher_running() { proc_running '^(.*\\)?ZwiftLauncher\.exe([[:space:]]|$)'; }
game_running()     { proc_running '^(.*\\)?ZwiftApp\.exe([[:space:]]|$)'; }

if ! launcher_running; then
  wine ZwiftLauncher.exe >"${TMPDIR:-/tmp}/zwift-launcher.log" 2>&1 &
  sleep 25
fi

# RunFromProcess starts the game from the launcher's process context and exits
# immediately — it is not the game's parent, so we cannot just wait on it.
wine RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe

# Wait for the game to appear. Generous: login, patching and asset load can be
# slow. If it never shows, leave everything alone and exit quietly.
appeared=0
for _ in $(seq 1 150); do            # up to ~5 min
  if game_running; then appeared=1; break; fi
  sleep 2
done
[ "$appeared" -eq 1 ] || exit 0

# Game is up, so patching is done and the launcher has no further job. Closing it
# by PID is safe — the game depends on wineserver, not the launcher (tested:
# SIGTERM to the launcher alone leaves the game running indefinitely).
#
# Do NOT use Zwift's own CloseLauncher.exe: it matches processes by name and
# kills ZwiftApp too, truncating the in-progress activity .fit. That is almost
# certainly the origin of the "never close the launcher" folklore.
launcher_pid=$(ps -eo pid,args --no-headers 2>/dev/null \
               | awk '$2 ~ /^(.*\\)?ZwiftLauncher\.exe$/ {print $1; exit}')
[ -n "${launcher_pid:-}" ] && kill -TERM "$launcher_pid" 2>/dev/null || true

# Wait for the game to exit.
while game_running; do sleep 1; done

# Deliberate pause: ZwiftApp flushes the in-progress activity .fit on exit, and
# tearing the prefix down too early truncates it. Do NOT remove this.
sleep 3
wineserver -k >/dev/null 2>&1 || true
