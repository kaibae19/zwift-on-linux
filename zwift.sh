#!/usr/bin/env bash
# Launch Zwift under wine.
#
# Two modes, chosen automatically:
#
#   LAUNCHER MODE (default when wine-staging is present)
#     Starts the launcher and leaves it alone. Its UI renders on staging, so you
#     log in there and click Play — which passes an auth token to the game, so it
#     logs in automatically. You also get update prompts and download progress.
#     The script then just waits and tears the prefix down when you quit.
#
#   AUTOSTART MODE (default on vanilla/distro wine)
#     The launcher window is blank there (README: wine's DirectComposition gap),
#     so there is nothing to click. RunFromProcess starts the game directly and
#     the useless blank launcher is closed once the game is up. Log in inside the
#     game itself.
#
# Override with ZWIFT_MODE=launcher or ZWIFT_MODE=autostart.
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

# Zwift patches by streaming files into a temp Downloads folder, so a non-empty
# folder means an update is in flight. Starting the game while the patcher is
# rewriting its files risks launching a half-updated build, and any fixed timeout
# is wrong when a patch can be several GB — so wait on *progress*, not a clock.
DL_DIR="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Temp/Zwift/Downloads"
patch_in_progress() { [ -d "$DL_DIR" ] && [ -n "$(ls -A "$DL_DIR" 2>/dev/null)" ]; }
dl_size() { du -sk "$DL_DIR" 2>/dev/null | cut -f1; }

# Wait while a patch is downloading. Gives up only if the size stops changing for
# STALL_LIMIT consecutive checks (i.e. genuinely stuck, not merely slow).
wait_for_patch() {
  patch_in_progress || return 0
  echo "Update in progress — waiting for it to finish before starting the game."
  local prev="" cur stall=0 STALL_LIMIT=40   # 40 x 15s = 10 min with no progress
  while patch_in_progress; do
    cur=$(dl_size)
    if [ "$cur" = "$prev" ]; then
      stall=$((stall+1))
      [ "$stall" -ge "$STALL_LIMIT" ] && { echo "Patch appears stalled; continuing anyway."; return 0; }
    else
      [ -n "$prev" ] && echo "  patching... ${cur:-0} KB staged"
      stall=0
    fi
    prev="$cur"
    sleep 15
  done
  echo "Update finished."
  sleep 5   # let the patcher move the last files into place
}

# Staging renders the launcher UI, so there is something worth clicking.
if [ -z "${ZWIFT_MODE:-}" ]; then
  if [ -x /opt/wine-staging/bin/wine ]; then ZWIFT_MODE=launcher; else ZWIFT_MODE=autostart; fi
fi

if ! launcher_running; then
  wine ZwiftLauncher.exe >"${TMPDIR:-/tmp}/zwift-launcher.log" 2>&1 &
  sleep 25
fi

if [ "$ZWIFT_MODE" = autostart ]; then
  # Never fire this mid-patch: the game's files may be being rewritten.
  wait_for_patch
  # RunFromProcess starts the game from the launcher's process context and exits
  # immediately — it is not the game's parent, so we cannot just wait on it.
  wine RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe
else
  echo "Launcher mode: log in and click Play. (ZWIFT_MODE=autostart to skip the UI.)"
fi

# Wait for the game to appear. Generous: login, patching and asset load can be
# slow. If it never shows, leave everything alone and exit quietly.
appeared=0
for _ in $(seq 1 450); do            # up to ~15 min (login takes as long as it takes)
  if game_running; then appeared=1; break; fi
  # Don't burn the budget while an update is downloading — a big patch can take
  # far longer than the poll window, and that is not a failure.
  if patch_in_progress; then wait_for_patch; continue; fi
  sleep 2
done
[ "$appeared" -eq 1 ] || exit 0

# In autostart mode the blank launcher has no further job once the game is up, so
# close it. Closing it by PID is safe — the game depends on wineserver, not the
# launcher (tested: SIGTERM to the launcher alone leaves the game running
# indefinitely).
#
# In launcher mode we deliberately leave it alone: on staging its UI is useful,
# and killing it here would also cut short the window you just logged in through
# (it can take tens of seconds to finish painting).
#
# Either way: do NOT use Zwift's own CloseLauncher.exe. It matches processes by
# name and kills ZwiftApp too, truncating the in-progress activity .fit. That is
# almost certainly the origin of the "never close the launcher" folklore.
if [ "$ZWIFT_MODE" = autostart ]; then
  launcher_pid=$(ps -eo pid,args --no-headers 2>/dev/null \
                 | awk '$2 ~ /^(.*\\)?ZwiftLauncher\.exe$/ {print $1; exit}')
  [ -n "${launcher_pid:-}" ] && kill -TERM "$launcher_pid" 2>/dev/null || true
fi

# Wait for the game to exit.
while game_running; do sleep 1; done

# Deliberate pause: ZwiftApp flushes the in-progress activity .fit on exit, and
# tearing the prefix down too early truncates it. Do NOT remove this.
sleep 3
wineserver -k >/dev/null 2>&1 || true
