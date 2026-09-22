# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This repo holds two unrelated tool families, each a collection of standalone scripts (no build system, no package manager, no shared dependencies between them):

1. **Modem management scripts** (`modemalice.sh`, `modemtimhub.sh`, `h2640.sh`) — bash CLIs that log into home router web UIs (Telecom Italia Alice, TIM Hub+, Poste Italiane H2640) via `curl` and expose operations like `wifilist`, `reboot`, `info`, `stats`.
2. **Video quality comparison tool** (`compare-video-quality.sh`, `compare-video-quality.ps1`, `compare-video-quality-gui.ps1`, `VideoQualityCompareCore.psm1`) — compares two folders of videos with matching (or similarly-named) files and recommends which copy to keep, based on real decoded-frame sharpness, not just file size.

## Commands

### Modem scripts
Run directly, no build step: `./modemalice.sh {wifilist|reboot|info|stats}`, `./h2640.sh {wlandhcp|wlanstatus|dnshostnames|dslstatus|wanstatus|ddnsstatus|reboot}`. Config (router IP, credentials) is edited at the top of each script, not passed as arguments.

### Video quality tool

Syntax-check without running:
```bash
bash -n compare-video-quality.sh
pwsh -NoProfile -Command '$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile("compare-video-quality.ps1",[ref]$t,[ref]$e);$e'
```

Manual smoke test (works on Linux/macOS with `pwsh` + `ffmpeg` installed — the PowerShell scripts are fully cross-platform except the GUI, which requires Windows):
```bash
mkdir -p /tmp/testA /tmp/testB
ffmpeg -y -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=6" -c:v libx264 -crf 16 -pix_fmt yuv420p "/tmp/testA/Film.mkv"
ffmpeg -y -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=6" -vf "scale=640:360,boxblur=3:1,scale=1280:720" -c:v libx264 -crf 34 -pix_fmt yuv420p "/tmp/testB/Film.mp4"
./compare-video-quality.sh /tmp/testA /tmp/testB /tmp/report 3          # bash version
pwsh -File ./compare-video-quality.ps1 /tmp/testA /tmp/testB /tmp/report2 3  # PowerShell version
```
The report should say "Consigliato: A" (A is the sharp/high-bitrate copy).

The GUI (`compare-video-quality-gui.ps1`) has a hidden `-SmokeTest -SmokeTestDirA <dir> -SmokeTestDirB <dir> -SmokeTestOutDir <dir>` mode built for automated testing: it fills the form, calls the real `$btnStart` click handler via `PerformClick()`, and exits 0/1 instead of blocking on `ShowDialog()`. Use this instead of trying to drive the GUI interactively.

### CI
`.github/workflows/test-video-quality-windows.yml` runs on `windows-latest` (real Windows, not a container) whenever `compare-video-quality.ps1`, `compare-video-quality-gui.ps1`, `VideoQualityCompareCore.psm1`, or the workflow itself changes. It installs ffmpeg via choco, generates synthetic test videos, and runs 5 checks with `continue-on-error: true` + a final summary step (so one push surfaces every failure instead of one per push cycle):
- CLI under `powershell.exe` (5.1) and `pwsh.exe` (7)
- GUI smoke test under both, plus one run with `pwsh -MTA` to force the STA auto-relaunch path to actually fire (see below) — without this, the relaunch code path goes untested because GitHub's `pwsh` shell already starts in STA.

There is no Linux CI; the bash script and the PowerShell scripts' non-GUI logic are only verified locally (see manual smoke test above) before pushing.

## Architecture

### Modem scripts
Each script is independent and self-contained (no shared lib). Same shape in all three: config block at top → `elablogin`/`login` functions building a session via `curl` (cookie jar in `$tmp`) → `operazione`/`operazione_data` helpers issuing authenticated requests → a `case` statement dispatching CLI subcommands. Auth schemes differ per router (MD5 challenge-response for `modemalice.sh`, SHA-256 session-token for the other two) — don't assume one script's login flow applies to another.

### Video quality tool

**Two independent implementations kept in behavioral lockstep**: `compare-video-quality.sh` (bash, for Linux/macOS) and the PowerShell trio (for Windows). They must produce the same report format, same scoring, same CLI argument order (`<dir_A> <dir_B> [output_dir] [num_campioni]`). When changing the algorithm, port the change to both.

**PowerShell split into three files on purpose:**
- `VideoQualityCompareCore.psm1` exports one function, `Invoke-VideoQualityComparison`, containing all the actual logic (file matching, ffprobe/ffmpeg calls, scoring, report writing). It never calls `exit` — failures are `throw`n so callers can catch them.
- `compare-video-quality.ps1` is a thin CLI wrapper: imports the module, calls the function, `Write-Error`+`exit 1` on catch.
- `compare-video-quality-gui.ps1` is a Windows Forms wrapper around the same function. All three files must ship together (the `.ps1` files `Import-Module (Join-Path $PSScriptRoot "VideoQualityCompareCore.psm1")`).

The module takes `-LogAction`/`-ProgressCallback`/`-ShouldCancel` scriptblock parameters instead of hardcoding `Write-Host`. The GUI passes closures that write to its own controls; these scriptblocks retain their defining scope even when invoked from inside the module (verified — this is not `$using:`-scoped, ordinary scriptblock capture is enough here since everything runs in one runspace). Do not rename `ProgressAction` back from `ProgressCallback` — it collides with a reserved common parameter PowerShell 7.4+ adds to every `[CmdletBinding()]` function and fails with "defined multiple times".

**Matching algorithm**: both implementations recurse into subdirectories, strip the extension, and match on a *normalized* name — lowercased, separators unified, then technical release tags stripped (resolution, source, codec, audio, language, release-group suffix) via a fixed regex/sed pattern list (`$TechTagPattern` in the `.psm1`, inline `sed` chain in the `.sh`). A bare year is extracted *before* the strip and re-appended if lost, so `"Titolo [2019]"` and `"Titolo 2019"` still match. This is intentionally exact-match-after-normalization, not fuzzy similarity — the tradeoff was chosen to avoid mispairing unrelated videos. Collisions (two files in the same source dir normalizing to the same key) are logged, not silently resolved.

**Scoring**: per matched pair, three ratios are computed (0–1, winner gets 1.0) and combined with fixed weights `$W_RES=0.35 $W_SHARP=0.45 $W_BPP=0.20`:
- resolution ratio from `width*height`
- sharpness ratio from average `ffmpeg blurdetect` value across N sample frames (**lower blur = sharper**, so the ratio inverts: `min/max`)
- bits-per-pixel ratio (`bitrate / (width*height*fps)`)

A gap under 5% between the two total scores yields "molto simile" instead of a forced pick. This heuristic is informational only — the script never deletes or moves files; it writes commented-out `mv`/`Move-Item` lines to `move-losers.sh`/`move-losers.ps1` for the user to review.

**Sample extraction trick**: one `ffmpeg` invocation per sample point per video gets both the blur measurement (`blurdetect` on the native-resolution stream, via `[0:v]split=2` filtergraph) *and* the padded comparison thumbnail, avoiding a second decode pass. Side-by-side comparison JPEGs are built afterward from the two thumbnails with `hstack`, labeled with `drawtext` when a usable font is found (best-effort — falls back to unlabeled `hstack` if not).

**Windows PowerShell 5.1 gotcha (load-bearing, do not remove)**: the three functions that shell out to `ffmpeg`/`ffprobe` (`Get-ProbeInfo`, `Get-SampleFrame`, `Merge-SideBySide`) each set `$ErrorActionPreference = "Continue"` locally. Under `"Stop"` (the module's default), Windows PowerShell 5.1 turns a native executable's stderr output into a terminating exception *even when redirected to `$null` or a file* — and ffmpeg/ffprobe always write to stderr on success. This was only caught by running on a real `windows-latest` GitHub Actions runner; it does not reproduce on pwsh/Linux, so don't "clean up" these lines based on local testing alone.

**STA relaunch**: Windows Forms requires an STA thread; `pwsh.exe` doesn't guarantee one. The GUI checks `[Threading.Thread]::CurrentThread.GetApartmentState()` at startup and, if not STA, relaunches itself via `Start-Process $psExe -ArgumentList @('-STA', '-File', $PSCommandPath, ...)` forwarding all bound parameters (including the `-SmokeTest*` ones — forgetting to forward them here is the most likely way to silently break the CI smoke test again).

**Numeric formatting**: all values embedded into ffmpeg arguments or written to CSV/report go through explicit `InvariantCulture` parsing/formatting (`ConvertTo-Double`, `Fmt` in the `.psm1`) — PowerShell's default `[double]`↔string conversions are culture-sensitive, and on an it-IT locale machine `"3.5"` can round-trip as `"3,5"`, corrupting `-ss` timestamps and CSV columns. Don't replace these with bare `.ToString()` or `[double]::Parse()` calls.
