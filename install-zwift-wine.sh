#!/usr/bin/env bash
# Zwift on Linux under wine — reproducible install.
#
# THE CRITICAL BIT: real Microsoft .NET 4.8 (winetricks dotnet48), NOT wine-mono.
# With wine-mono, ZwiftLauncher.exe exits cleanly with code 200 and logs only
# "Failed to get telemetry config" — no crash, no wine err: lines, nothing under
# WINEDEBUG=+seh. Effectively undiagnosable. Do not substitute wine-mono.
#
# Usage: ./install-zwift-wine.sh
#
# Env:
#   WINEPREFIX      prefix location  (default ~/Games/zwift/prefix)
#   WINE_CHANNEL    staging (default) | distro
#                   staging adds the WineHQ repo and installs winehq-staging,
#                   which is what makes the Zwift launcher UI render. On distro
#                   wine the launcher is a blank window.
#   SKIP_DEPS=1     don't touch apt  (for non-apt distros — install deps yourself)
set -euo pipefail

PREFIX="${WINEPREFIX:-$HOME/Games/zwift/prefix}"
DL="${ZWIFT_DL:-$HOME/Games/zwift-dl}"
ZDIR="$PREFIX/drive_c/Program Files (x86)/Zwift"
LAUNCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zwift.sh"

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG=-all

# --- deps -------------------------------------------------------------------
# Default to wine-staging from WineHQ, NOT the distro package. Staging's dcomp
# patchset is what makes the Zwift launcher UI actually render; on distro wine it
# is a blank window (see README). Set WINE_CHANNEL=distro to opt out.
WINE_CHANNEL="${WINE_CHANNEL:-staging}"

add_winehq_repo() {
  local codename
  codename=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
  [ -n "$codename" ] || codename=$(lsb_release -cs 2>/dev/null || true)
  [ -n "$codename" ] || { echo "    cannot determine distro codename"; return 1; }

  # Does WineHQ actually publish for this release?
  if ! curl -fsSL -o /dev/null "https://dl.winehq.org/wine-builds/ubuntu/dists/$codename/"; then
    echo "    WineHQ publishes nothing for '$codename'"
    return 1
  fi

  echo "    adding WineHQ repo for $codename"
  sudo mkdir -pm755 /etc/apt/keyrings
  # The key is ASCII-armored; apt rejects it as an "unsupported filetype" unless
  # dearmored, and the shipped .sources points Signed-By at the .key — repoint it.
  curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/winehq-archive.gpg || return 1
  sudo chmod 644 /etc/apt/keyrings/winehq-archive.gpg
  sudo curl -fsSL -o "/etc/apt/sources.list.d/winehq-$codename.sources" \
    "https://dl.winehq.org/wine-builds/ubuntu/dists/$codename/winehq-$codename.sources" || return 1
  sudo sed -i 's#winehq-archive\.key#winehq-archive.gpg#' \
    "/etc/apt/sources.list.d/winehq-$codename.sources"
  sudo apt-get update -qq || return 1
}

if [ "${SKIP_DEPS:-0}" != "1" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "==> [1/6] packages"
    sudo apt-get install -y --no-install-recommends winetricks cabextract curl

    if [ "$WINE_CHANNEL" = staging ] && add_winehq_repo \
       && sudo apt-get install -y winehq-staging; then
      echo "    installed wine-staging (launcher UI will render)"
    else
      [ "$WINE_CHANNEL" = staging ] && \
        echo "    !! falling back to distro wine — the launcher window will be BLANK." && \
        echo "       See README: log in inside the game, not the launcher."
      sudo apt-get install -y --no-install-recommends wine
    fi
  else
    echo "==> [1/6] non-apt system: install wine (preferably wine-staging 11.16+),"
    echo "    winetricks and cabextract yourself, then re-run with SKIP_DEPS=1"
    exit 1
  fi
else
  echo "==> [1/6] skipping dependency install (SKIP_DEPS=1)"
fi

# Prefer wine-staging if present — it installs to /opt/wine-staging/bin and does
# NOT put itself on PATH. Checking it first matters: the distro's libwine may
# still be installed, and picking its wineserver would mix wine versions.
#
# GOTCHA: Debian/Ubuntu keep wineserver out of PATH either way. winetricks then
# silently does NOTHING and still exits 0, printing only
# "warning: wineserver not found!".
if [ -x /opt/wine-staging/bin/wineserver ]; then
  export PATH="/opt/wine-staging/bin:$PATH"
elif ! command -v wineserver >/dev/null 2>&1; then
  for d in /usr/lib/*/wine /usr/lib/wine /usr/lib64/wine /opt/wine*/bin; do
    if [ -x "$d/wineserver" ]; then export PATH="$d:$PATH"; break; fi
  done
fi
command -v wineserver >/dev/null 2>&1 || {
  echo "FATAL: wineserver not found on PATH. Locate it and add its directory to PATH."
  echo "  try: find /usr -name wineserver -type f 2>/dev/null"
  exit 1
}
echo "    wineserver: $(command -v wineserver)"
echo "    wine:       $(wine --version 2>/dev/null || echo unknown)"

# --- prefix -----------------------------------------------------------------
echo "==> [2/6] 64-bit prefix at $PREFIX"
mkdir -p "$PREFIX"
# Suppress the mono/gecko prompts; real .NET goes in next.
WINEDLLOVERRIDES="mscoree,mshtml=d" wineboot --init
wineserver -w

# --- the important part -----------------------------------------------------
echo "==> [3/6] .NET 4.8 + d3dcompiler_47 + win10   (slow, ~5-10 min)"
# dotnet48 removes wine-mono from the prefix. That is expected and required.
winetricks -q -f dotnet48 d3dcompiler_47 win10
# Release >= 0x80eb1 (528049) means 4.8 actually landed.
if grep -aq '"Release"=dword:00080eb1' "$PREFIX/system.reg" 2>/dev/null; then
  echo "    .NET 4.8 confirmed"
else
  echo "    WARNING: .NET 4.8 not confirmed in registry — the launcher will likely"
  echo "             exit with code 200. Check that winetricks actually ran."
fi

# NOTE: do NOT install DXVK. Zwift renders in OpenGL and loads no d3d11/dxgi;
# DXVK attaches only to the launcher UI and does nothing for the game.

# --- Zwift ------------------------------------------------------------------
echo "==> [4/6] Zwift installer"
mkdir -p "$DL"
[ -s "$DL/ZwiftSetup.exe" ] || \
    curl -fsSL --max-time 600 -o "$DL/ZwiftSetup.exe" "https://cdn.zwift.com/app/ZwiftSetup.exe"
# Inno Setup. Bundled prerequisites (VC++ redist, DirectX, WebView2) install fine
# under wine. ZwiftSetup.exe is 32-bit but runs via new-WoW64 with no i386 packages.
wine "$DL/ZwiftSetup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL || true

# Do NOT `wineserver -w` here. Inno's post-install step starts
# "ZwiftLauncher.exe UpdateLaunch", which stays running indefinitely, so waiting
# for all wine processes to exit hangs forever. (This only shows up once .NET 4.8
# is working — with wine-mono the launcher exited 200 by itself and masked it.)
# Give the installer a moment to finish writing, then tear the prefix down.
sleep 5
wineserver -k >/dev/null 2>&1 || true
sleep 2
[ -f "$ZDIR/ZwiftLauncher.exe" ] || { echo "FATAL: Zwift did not install to $ZDIR"; exit 1; }

# --- RunFromProcess ---------------------------------------------------------
echo "==> [5/6] RunFromProcess (required to start the game from the launcher)"
if [ ! -f "$ZDIR/RunFromProcess-x64.exe" ]; then
  # NOTE: the runfromprocess-x64.zip URL 404s; both binaries are in the base zip.
  curl -fsSL --max-time 120 -A "Mozilla/5.0" -o "$DL/runfromprocess.zip" \
      "https://www.nirsoft.net/utils/runfromprocess.zip"
  unzip -o -j "$DL/runfromprocess.zip" "RunFromProcess-x64.exe" "RunFromProcess.exe" -d "$ZDIR"
fi

# --- quality of life --------------------------------------------------------
echo "==> [6/6] desktop integration"
# GNOME pings windows every 5s; Zwift's asset load trips it and throws
# "not responding - Cancel or Wait" dialogs.
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.mutter check-alive-timeout 60000 2>/dev/null \
    && echo "    raised mutter check-alive-timeout to 60s" || true
fi

# The shortcut Zwift's installer creates does NOT work (it runs the .lnk, which
# starts only the launcher). Write one that calls zwift.sh instead.
# CRITICAL: no Path= key — wine's working dir contains a colon and GNOME then
# rejects the entry with "has errors or points to a program without permissions".
if [ -d "$HOME/Desktop" ] && [ -f "$LAUNCHER" ]; then
  cat > "$HOME/Desktop/Zwift.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Zwift
Comment=Zwift under wine
Exec=$LAUNCHER
Terminal=false
StartupNotify=true
StartupWMClass=zwiftapp.exe
Categories=Game;
EOF
  chmod +x "$HOME/Desktop/Zwift.desktop"
  gio set "$HOME/Desktop/Zwift.desktop" metadata::trusted true 2>/dev/null || true
  echo "    wrote ~/Desktop/Zwift.desktop"
fi

echo
echo "Done.  Launch with:  $LAUNCHER"
echo
if [ -x /opt/wine-staging/bin/wine ]; then
  cat <<'EOF'
  * wine-staging is installed, so the LAUNCHER UI WORKS. Log in there and click
    Let's Go — the game receives an auth token and logs in automatically.
  * The launcher starts blank and paints progressively over tens of seconds.
    That is normal; don't assume it failed.
  * zwift.sh leaves the launcher running so you can see update progress.
EOF
else
  cat <<'EOF'
  * Running on distro wine, so the launcher window will be BLANK white/black.
    WebView2 cannot paint into the wine window. Log in INSIDE THE GAME.
  * zwift.sh starts the game directly and closes the blank launcher once the
    game is up. Closing it by PID is safe; the game depends on wineserver, not
    the launcher.
EOF
fi
cat <<'EOF'
  * NEVER use Zwift's own CloseLauncher.exe — it kills ZwiftApp too and
    truncates your in-progress activity .fit.
  * Sensors: use the Zwift Companion app. Direct BLE cannot work under wine.
    Your phone must be on the same subnet as this machine.
EOF
