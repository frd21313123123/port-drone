# DroneFlames — PC port

Windows (x64) port of the Godot 4.7.2 game **DroneFlames**, made from the Android build:
wide-screen UI, Steam multiplayer (Spacewar, AppID 480), a setting for deposit depletion,
and automatic updates from this repository's GitHub Releases.

> **The game itself (code and art) belongs to its authors.** This repository is a derivative
> of their closed-beta APK. Do not make it public / do not distribute builds without their permission.

## For players

Download `DroneFlames.exe` from [Releases](../../releases/latest) and run it — one file.
On the first start it downloads the native libraries it needs (Steam, online) next to itself
and restarts once. After that, on every start it checks GitHub: if a newer release exists,
a window **«this version is outdated»** appears; **UPDATE** downloads the new `DroneFlames.exe`,
replaces the old one and starts it. No network = the game starts as is.

Steam multiplayer: start Steam → Multiplayer → STEAM tab → CREATE, then *Invite friends*.
Everybody in a match must have the same version (the updater makes sure of it).

## For developers

```
game/            the game project (plain GDScript restored from the APK + the PC port in game/pc/)
libs/            native libraries (WebRTC, GodotSteam, steam_api64.dll) shipped as DroneFlames-libs-rN.zip
tools/build.py   packs game/ into a PCK and appends it to the Windows export template -> dist/DroneFlames.exe
tools/fetch_godot.py   downloads Godot 4.7.2 (editor + Windows template)
tools/gdc2gd.py        the decompiler used to get game/ out of the APK's binary scripts
.github/workflows/build.yml   CI
```

### Releases

* **Bump `version` in `game/pc/version.cfg` and push to `main`** — if there is no release `v<version>` yet, CI publishes it.
  (A tag `v0.32.2` or running the *Build* workflow with `release_version` works too.)
  CI builds `DroneFlames.exe`, `DroneFlames-libs-r1.zip`, `SHA256SUMS.txt` and publishes the release.
  Players' games see it on next start and offer the update.
* The released version is written into the exe (CI writes it into the exe and into `Menus.VERSION`, which the multiplayer lobby compares).
* Changed anything in `libs/`? Bump `libs_rev` in `game/pc/version.cfg` — the game re-downloads the libs.
* Version order: all numbers in the tag are compared left to right (`0.32.2` > `0.32.1` > `0.32.0.1`).

### Updater (game/pc/updater.gd)

`game/override.cfg` makes `res://pc/boot.tscn` the start scene: it asks
`https://api.github.com/repos/<repo>/releases/latest` (repo is written by CI = `$GITHUB_REPOSITORY`),
and only then loads the real game scene. The update is a single `DroneFlames.exe` asset; Windows allows renaming a
running exe, so the new file is put in place, the old one becomes `DroneFlames.exe.old` (deleted at the next start).
The API must be reachable without a token: **updates work for public releases only.**

Debug-build test hooks: `DF_UPDATE_API=<url>`, `DF_UPDATE_ASSET=<name>`; `DF_NO_UPDATE=1` skips the check.

### Local build

```
python3 tools/fetch_godot.py godot_dl
python3 tools/build.py --godot godot_dl/godot --template godot_dl/windows_release_x86_64.exe --version 0.33.2.2 --repo you/repo --out dist
```

### Performance checks

`python3 tools/check_performance.py` runs CPU regression checks against the current source in a temporary PCK, with isolated save files. No Windows export template is needed. Use `--mode benchmark --size 2048 --bots 4` for a late-game simulation benchmark; JSON results and logs go to `dist/performance/`. See [performance validation](docs/performance.md) for checkpoint comparisons and limitations.
