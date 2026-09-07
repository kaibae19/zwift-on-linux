# Zwift on Linux (wine)

Running Zwift under wine, written down properly — including the failure that
costs people hours and isn't documented anywhere obvious.

Verified working: **Zwift 1.120.0 (game 1.0.164452), launcher 1.1.18, wine 10.0,
Ubuntu 26.04, NVIDIA 595.84** — September 2026.

> ### This is a moving target
>
> Zwift force-updates often and changes its launcher, its .NET dependencies and
> its login flow without warning. wine and distro packaging move too. Anything
> here can go stale — **if a step no longer matches reality, trust reality.**
> Version numbers above are what it was last verified against, not requirements.
> Issues and PRs correcting drift are very welcome.

---

## The one that will get you

**Use real Microsoft .NET 4.8. Do not use wine-mono.**

With wine-mono in the prefix, `ZwiftLauncher.exe` exits *cleanly* with **code
200** and logs exactly one useful line:

```
[ERROR] Failed to get telemetry config
```

No crash. No wine `err:` output. Nothing under `WINEDEBUG=+seh`. No SEH
exception. It is a deliberate, silent exit and there is almost nothing to grab
onto. `winetricks dotnet48` fixes it immediately.

Wrong turns worth skipping, all of which look plausible:

- The empty `URL=""` in `Launcher_ver_cur.xml` is **normal** — the launcher
  writes that itself. Not the bug.
- A missing WebView2 runtime is **not** the bug; Zwift's installer installs it
  and it works under wine.
- An interrupted installer is **not** the bug.

**Status of the scripts:** every step here was verified by hand on a working
install, and `zwift.sh` is in daily use. `install-zwift-wine.sh` encodes that
same sequence but has not yet been run start-to-finish on a clean machine — if
you hit a snag running it fresh, an issue would be genuinely useful.

## Quick start

```bash
git clone https://github.com/kaibae19/zwift-on-linux
cd zwift-on-linux
./install-zwift-wine.sh      # installs deps, builds the prefix, installs Zwift
./zwift.sh                   # launch
```

Then **log in inside the game**, not in the launcher (see below).

## What the install actually does

1. Installs `wine winetricks cabextract` (+ `xdotool` for window handling)
2. Creates a 64-bit prefix
3. `winetricks -q dotnet48 d3dcompiler_47 win10` — **real .NET, not wine-mono**
4. Runs Zwift's installer silently; its bundled VC++ redist, DirectX and
   WebView2 all install fine under wine
5. Drops in NirSoft `RunFromProcess`, needed to start the game
6. Writes a launch script

## Gotchas

### The launcher window is blank — that's normal

It renders white, then black. WebView2 runs fine but cannot paint into the wine
window. **You do not log in there.** Log in inside the game itself. The launcher
still does its real job (patching and downloading) invisibly.

### The launcher must stay running — never close it mid-game

`RunFromProcess` starts `ZwiftApp.exe` as a **child** of the launcher, so killing
the launcher kills the game. Zwift ships its own `CloseLauncher.exe`; on Windows
that's safe, under wine it is not — it takes the game down instantly and leaves
the in-progress activity `.fit` truncated. Close the launcher only *after* the
game exits. `zwift.sh` does this for you.

### `wineserver` may not be on your PATH

On Debian/Ubuntu it lives in `/usr/lib/x86_64-linux-gnu/wine/`. If it isn't on
`PATH`, **winetricks silently does nothing and still exits 0**, printing only:

```
warning: wineserver not found!
```

Export `PATH` first and verify, or you'll spend a while wondering why `dotnet48`
had no effect.

### WebView2 needs its sandbox off

```bash
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu"
```

Do **not** also pass `--in-process-gpu` — combined with `--disable-gpu` it kills
the browser process (`WebView2 process failed — Kind: BrowserProcessExited`).

### Detecting whether Zwift is running is a trap

`ZwiftApp.exe`'s process `comm` is **`main`**, not `ZwiftApp.exe` — wine names it
from the internal thread — so `pgrep -x ZwiftApp.exe` matches **nothing** while
the game is plainly running. The launcher's comm *is* exe-derived but Linux
truncates comm to 15 chars (`ZwiftLauncher.e`). And `pgrep -f` is useless because
`wine RunFromProcess-x64.exe ZwiftLauncher.exe ZwiftApp.exe` carries both names
in its own command line. Match the first token of `args`:

```bash
ps -eo args --no-headers | awk '$1=="ZwiftApp.exe"{f=1} END{exit !f}'
```

### `.desktop` shortcuts: no `Path=` key

The shortcut Zwift's installer creates does not work — it runs the `.lnk`, which
starts only the launcher (blank window, no route into the game).

If you write your own, **omit `Path=`**. wine's natural working directory
(`.../dosdevices/c:/Program Files (x86)/Zwift`) contains a **colon**, and GNOME
rejects the whole entry with the misleading *"this .desktop file has errors or
points to a program without permissions"* — even though `desktop-file-validate`
passes and permissions are fine. Point `Exec` at `zwift.sh`, which does its own
`cd`.

### "Not responding — Cancel or Wait" while loading

GNOME/Mutter pings windows every 5s; Zwift's asset load blows through that.

```bash
gsettings set org.gnome.mutter check-alive-timeout 60000
# revert: gsettings reset org.gnome.mutter check-alive-timeout
```

### Fullscreen + minimize = black screen

Alt-tabbing out of fullscreen Zwift under Xwayland loses the GL context and it
returns black. Run windowed if you multitask; irrelevant on a dedicated box.

### The 32-bit installer needs no i386 packages

`ZwiftSetup.exe` is 32-bit, but wine 10.0's new-WoW64 runs it through the 64-bit
host. No `wine32:i386` required.

### `runfromprocess-x64.zip` 404s

That URL is dead. Both binaries are inside the base `runfromprocess.zip`.

## Sensors: use the Companion app

**Direct Bluetooth cannot work under wine.** Zwift's `BleWin10Lib.dll` needs real
Windows Bluetooth APIs that wine does not implement.

Use the **Zwift Companion app**: your phone holds the BLE link to the trainer and
bridges it over the LAN. This is platform-independent and works well.

Companion finds the PC by **UDP broadcast**, so the phone must be on the **same
subnet**. If it can't find your machine, suspect that first. On hosts with many
virtual interfaces (docker/libvirt bridges), Zwift may broadcast on the wrong one
— a machine without a pile of bridges avoids the problem entirely.

ANT+ via USB is not covered here; the Companion route is the reliable one.

## Performance: Zwift is CPU-bound, and it's OpenGL

**Zwift renders in OpenGL, not Direct3D.** Its own log says so:

```
OpenGL 4.6.0 NVIDIA 595.84 initialized
```

`ZwiftApp.exe` loads **zero** d3d11/dxgi. Installing DXVK does nothing for the
game — DXVK attaches only to the launcher (d3d9) and its WebView2 (d3d11). Save
yourself the trouble. A pleasant side effect: none of the Vulkan-maturity worries
about older GPUs apply.

**It is CPU-bound.** On one test rig, going from 1080p to 4K at max settings —
4× the pixels — cost about **2 FPS**:

| | 1080p | 3840x2160 max |
|---|---|---|
| FPS in-world | ~64-67 | ~63 |
| GPU utilization | 27% | 41% |
| Game process CPU | 115% | 112% |

The GPU never got past ~41% while one CPU thread stayed pinned. Frame rate is set
by **single-thread CPU performance**. Zwift also auto-selects its render
resolution from the GPU it detects, so weaker cards degrade gracefully rather
than falling over. Budget for CPU, not GPU.

### Zwift logs its own FPS

```bash
grep -oE "FPS [0-9.]+" "$WINEPREFIX/drive_c/users/$USER/AppData/Local/Zwift/Logs/Log.txt"
```

Renderer-agnostic and needs no tooling. Note **MangoHud does not work here** — it
loads into the process but never hooks wine's OpenGL path, so it neither draws
nor logs. It would only work if something were on Vulkan, which for Zwift it
never is.

## Updates

The launcher works, so Zwift's normal update path works — it downloaded the full
~4.7 GiB itself. Updates should apply as they do on Windows.

If the launcher ever can't, Zwift's CDN is unauthenticated and serves the full
manifest (~19,600 files):

```
https://cdn.zwift.com/gameassets/Zwift_Updates_Root/Zwift_ver_cur.xml
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| Launcher exits code 200, "Failed to get telemetry config" | wine-mono instead of real .NET 4.8 |
| `winetricks` does nothing, exits 0 | `wineserver` not on `PATH` |
| Launcher window blank white/black | Normal. Log in inside the game. |
| WebView2 `BrowserProcessExited` | `--in-process-gpu` passed alongside `--disable-gpu` |
| Game dies when launcher closes | Expected — launcher is the game's parent |
| `.desktop` "has errors or points to a program without permissions" | A `Path=` key containing a colon |
| Companion can't find the PC | Phone on a different subnet, or broadcast on a virtual bridge |
| `pgrep` says the game isn't running | Its comm is `main`; match on args |

## Contributing

Corrections are the most valuable contribution here, since Zwift changes under
us. If something no longer matches, please open an issue with your Zwift version,
wine version and distro.

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with or endorsed by Zwift. `RunFromProcess` is by NirSoft.
