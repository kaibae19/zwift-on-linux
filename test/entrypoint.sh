#!/usr/bin/env bash
# Runs install-zwift-wine.sh in a clean container and asserts the outcomes that
# actually matter. Exits non-zero on the first hard failure.
set -uo pipefail

PREFIX="$HOME/Games/zwift/prefix"
ZDIR="$PREFIX/drive_c/Program Files (x86)/Zwift"
pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "=============================================="
echo " Zwift-on-Linux install test"
echo " $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "=============================================="

# wine needs a display even for headless installs (winetricks, wineboot).
Xvfb :99 -screen 0 1280x1024x24 >/dev/null 2>&1 &
export DISPLAY=:99
sleep 3
xdpyinfo -display :99 >/dev/null 2>&1 || echo "  NOTE: Xvfb may not be up; continuing"

echo
echo "--- running install-zwift-wine.sh ---"
# Bounded: a hang here is a real failure mode. Inno's post-install step starts
# "ZwiftLauncher.exe UpdateLaunch" and leaves it running, so any `wineserver -w`
# in the installer blocks forever. Fail fast instead of burning the CI budget.
timeout 1200 "$HOME/repo/install-zwift-wine.sh"
rc=$?
if [ "$rc" -eq 124 ]; then
  echo "--- installer TIMED OUT after 20 min ---"
  echo "    likely a wineserver -w waiting on a process that never exits"
  ps -eo pid,etime,args --no-headers 2>/dev/null | grep -iE "wine|zwift" | head -10 | sed 's/^/    /'
else
  echo "--- installer exited $rc ---"
fi

echo
echo "--- assertions ---"

# 1. THE important one. Release 0x00080eb1 == 528049 == .NET Framework 4.8.
if grep -aq '"Release"=dword:00080eb1' "$PREFIX/system.reg" 2>/dev/null; then
  ok ".NET 4.8 installed (Release=0x00080eb1)"
else
  bad ".NET 4.8 NOT installed — launcher will exit 200"
fi

# 2. wine-mono must be gone; dotnet48 removes it.
if [ -d "$PREFIX/drive_c/windows/mono" ]; then
  bad "wine-mono still present (dotnet48 did not replace it)"
else
  ok "wine-mono removed"
fi

# 3. Guard against the silent-winetricks trap. NOTE: check the binary EXISTS,
#    not whether it is on *this* shell's PATH — the installer exports PATH in its
#    own process, so testing here would fail spuriously (it did, first run).
# Test each candidate separately: `ls a b` returns non-zero when ANY argument is
# missing, so a combined check fails even when wineserver plainly exists.
# Unmatched globs stay literal and simply fail the -x test.
ws=""
for cand in $(command -v wineserver 2>/dev/null) \
            /usr/lib/*/wine/wineserver /usr/lib/wine/wineserver \
            /usr/lib64/wine/wineserver /opt/wine*/bin/wineserver; do
  [ -x "$cand" ] && { ws="$cand"; break; }
done
if [ -n "$ws" ]; then
  ok "wineserver binary present ($ws)"
else
  bad "wineserver binary not found anywhere — winetricks would no-op silently"
fi

# 4. Zwift itself.
[ -f "$ZDIR/ZwiftLauncher.exe" ] && ok "ZwiftLauncher.exe installed" \
                                 || bad "ZwiftLauncher.exe missing"
[ -f "$ZDIR/RunFromProcess-x64.exe" ] && ok "RunFromProcess-x64.exe present" \
                                      || bad "RunFromProcess-x64.exe missing"
[ -f "$PREFIX/drive_c/windows/system32/d3dcompiler_47.dll" ] \
    && ok "d3dcompiler_47 installed" || bad "d3dcompiler_47 missing"

# 5. The regression test this repo exists for: the launcher must not exit 200.
#    Note it may exit non-zero for other reasons in a container (no GPU, no real
#    display, no login) — 200 specifically is the wine-mono signature.
echo
echo "--- launching ZwiftLauncher.exe (watching for exit 200) ---"
export WINEPREFIX="$PREFIX" WINEDEBUG=-all
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu"
if ! command -v wineserver >/dev/null 2>&1; then
  for d in /usr/lib/*/wine /usr/lib/wine /usr/lib64/wine; do
    [ -x "$d/wineserver" ] && { export PATH="$d:$PATH"; break; }
  done
fi
cd "$ZDIR" 2>/dev/null || true
timeout 120 wine ZwiftLauncher.exe >/tmp/launcher.log 2>&1
rc=$?
echo "  launcher exit code: $rc"
if [ "$rc" -eq 200 ]; then
  bad "launcher exited 200 — the wine-mono failure mode is back"
  echo "  --- launcher log ---"; tail -15 /tmp/launcher.log | sed 's/^/    /'
else
  ok "launcher did not exit 200"
fi

if grep -q "Failed to get telemetry config" /tmp/launcher.log 2>/dev/null; then
  # This line alone is not fatal — it appears transiently before CNL retries.
  # Combined with exit 200 it is the wine-mono signature.
  echo "  NOTE: 'Failed to get telemetry config' seen (only fatal alongside exit 200)"
fi
if grep -q "Launcher Version Number" /tmp/launcher.log 2>/dev/null; then
  ok "launcher initialised its UI ($(grep -o 'Launcher Version Number.*' /tmp/launcher.log | head -1))"
fi

echo
echo "=============================================="
echo " passed: $pass   failed: $fail"
echo "=============================================="
[ "$fail" -eq 0 ]
