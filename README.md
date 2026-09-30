# Splicewright

A native macOS video editor for Apple silicon, laid out like Premiere Pro. It handles SDR (Rec.709) and HDR (HLG, PQ) footage in H.264, HEVC and ProRes, in `.mov` and `.mp4`, up to 4K60.

Status: **M1**. The workspace is in place. You can import media into bins, inspect format details, and play clips in the Source monitor with In/Out marks and JKL shuttle. Timeline editing is next (M2). See [docs/PLAN.md](docs/PLAN.md) for the roadmap.

## Quick start

Requirements: **macOS 15+** and **Xcode 16+**. Nothing else is needed: no Homebrew, no Apple Developer account.

1. `git clone` this repository.
2. Open `Splicewright.xcodeproj`.
3. Press **⌘R**.

Or from Terminal:

```sh
make doctor   # checks macOS / Xcode and explains anything missing
make run      # builds the Debug app and launches it
```

When the app opens, choose **New Document**, then import media. You can press ⌘I, drag files or folders onto the Project panel, or click Import. Double-click a clip to open it in the Source monitor.

### Make targets

| Command | What it does |
|---|---|
| `make run` | Build Debug and launch |
| `make build` | Build Debug |
| `make test` | Run all unit tests (`swift test`) |
| `make release` | Build the Release app |
| `make dmg` | Package the Release app as `build/Splicewright.dmg` |
| `make fixtures` | Generate sample SDR/HDR clips in `TestMedia/` (needs `ffmpeg`) |
| `make doctor` | Check build prerequisites |
| `make generate` | Regenerate the Xcode project from `project.yml` (maintainers) |

### Prebuilt app

Pushing a `v*` tag makes CI attach a `.dmg` to a GitHub Release. These builds are ad-hoc signed and not notarized yet, so the first time you open the app, right-click it and choose **Open**. Notarized builds need a paid Apple Developer account and are planned for M8.

### Troubleshooting

- **"xcodebuild requires Xcode" or "Command Line Tools" errors:** run `sudo xcode-select -s /Applications/Xcode.app`.
- **License prompt:** run `sudo xcodebuild -license accept`, or open Xcode once.
- **macOS asks for folder access on import:** allow it. Splicewright reads media from where it is and never copies or modifies it.

## Keyboard shortcuts

These follow Premiere Pro's defaults.

| Key | Action |
|---|---|
| Space | Play / stop |
| J / K / L | Shuttle reverse / stop / forward (press again for 2×, 4×, 8×) |
| ← / → | Step one frame (⇧ for five) |
| I / O | Mark In / Out |
| ⇧I / ⇧O | Go to In / Out |
| ⌥I / ⌥O / ⌥X | Clear In / Out / both |
| Home / End | Go to start / end |
| Return | Open the selected clip in the Source monitor |
| V A B N R C Y U P H Z T | Tools (Selection, Track Select, Ripple, Rolling, Rate Stretch, Razor, Slip, Slide, Pen, Hand, Zoom, Type) |
| ⌘I | Import |
| ⌘B | New bin |

Transport keys apply to the active panel, which is outlined in blue. Click a panel to activate it.

## Project layout

```
App/                         App entry point and Info.plist
Packages/SplicewrightKit/
  Sources/SWCore/            Pure Swift model: time, timecode, media metadata, project, key map
  Sources/SWMedia/           AVFoundation: probing, import, thumbnails, waveforms
  Sources/SWUI/              SwiftUI/AppKit workspace and panels
  Tests/SWCoreTests/         Swift Testing; also runs on Linux
  Tests/SWMediaTests/        XCTest; synthesizes its own clips with AVAssetWriter
project.yml                  XcodeGen spec (the generated .xcodeproj is committed)
docs/PLAN.md                 Architecture and milestones
```

`SWCore` imports only Foundation, so the editing model can be tested anywhere. Run `swift test --package-path Packages/SplicewrightKit` on Linux and only the SWCore tests run.

## Format support (v1 target)

| | Import | Export (M5) |
|---|---|---|
| H.264 | 8-bit SDR up to 4K60 | SDR Rec.709 |
| HEVC | 8/10-bit SDR, HLG, PQ; iPhone Dolby Vision is read as HLG | Main (SDR), Main10 (HLG, PQ) |
| ProRes | 422 Proxy/LT/422/HQ, 4444 | 422 family |
| Containers | .mov, .mp4, .m4v; audio .wav .aif .caf .m4a .mp3 | .mov, .mp4 |
