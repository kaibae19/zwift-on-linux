# Notes for WineHQ bug 58921

<https://bugs.winehq.org/show_bug.cgi?id=58921> — "WebView2 does not work with
Windows version setting 8.1 or newer" (bug 59370 is a duplicate of it).

That bug already identifies the cause (DirectComposition returning `E_NOTIMPL`)
and comment #10 already reports that the wine-staging dcomp patchset fixes it.
Our results agree, so most of what we found is confirmation rather than news.

**Two data points that may still be worth adding as a comment:**

1. **The `Version=win7`/`win8` override no longer works with WebView2 152.**
   Comment #0's per-application override for `msedgewebview2.exe` — and setting
   the *entire prefix* to win8 — both failed here:

   - vanilla wine 10.0 (Ubuntu 26.04), WebView2 Runtime **152.0.4191.66**
   - per-app `Version=win8` for `msedgewebview2.exe`: still blank,
     `fixme:dcomp:DCompositionCreateDevice3` still logged
   - whole prefix set to win8: 4 `msedgewebview2` processes spawned, still blank,
     DComp still called

   Previous reports in the bug cover WebView2 150 and 151, where the override
   reportedly still worked on vanilla. If that is a real regression between 151
   and 152, the comment #0 workaround should probably be marked as version-bound.

2. **wine-staging 11.16 confirmed fixing it on a further application.**
   Same prefix, Zwift launcher 1.1.18 (a .NET WinForms host using WebView2 in
   composition mode):

   - vanilla wine 10.0 → blank window
   - wine-staging 11.16 → UI renders, login works, launching the game works

   Also possibly useful for triage: on staging the `fixme:dcomp` count *rises*
   from 1 to ~26, moving from a single failed `DCompositionCreateDevice3` to
   `dcomp:device` and `dcomp:visual` messages — i.e. it now gets deep enough into
   the composition path to log the individual unimplemented methods.

   Chromium-side flags do not substitute for the patchset. Measured on vanilla,
   each with a fresh WebView2 user-data folder, all producing a uniformly black
   window (greyscale stddev 0.00000, 1 unique colour): `--no-sandbox`,
   `--disable-gpu`, `--disable-features=CalculateNativeWinOcclusion`,
   `--disable-direct-composition`, `--disable-gpu-compositing`, and combinations.

**Affected application:** Zwift. The installer is a free download
(<https://cdn.zwift.com/app/ZwiftSetup.exe>) and the launcher reaches its blank
window without a login or subscription, so it reproduces without an account.
