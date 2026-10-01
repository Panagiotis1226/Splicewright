# Splicewright

A native macOS video editor for Apple silicon, laid out like Premiere Pro. It handles SDR (Rec.709) and HDR (HLG, PQ) footage in H.264, HEVC and ProRes, in `.mov` and `.mp4`, up to 4K60.

Status: **M5**. You can:

- import media into bins and check its format details
- mark In/Out in the Source monitor
- edit on a multi-track timeline, with Insert/Overwrite, ripple and rolling trims, slip, slide, razor and ripple delete
- play the sequence in the Program monitor through a Metal compositor that handles SDR and HDR (HLG/PQ), with an optional clipping overlay
- override how a clip's color is read (right-click ▸ Interpret Footage)
- export to H.264, HEVC, HEVC 10-bit HLG/PQ or ProRes (422 HQ, 422, LT, Proxy) at 480p up to 4K and 23.976 up to 120 fps, with a quality preset or a custom bitrate, and tone-map HDR sequences to SDR deliverables

Transitions and titles are next (M6). See [docs/PLAN.md](docs/PLAN.md) for the roadmap.

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

When the app opens, choose **New Document**, then:

1. **Import media:** press ⌘I, click Import, or drag files or folders onto the Project panel. Run `make fixtures` for sample clips; they're written to `TestMedia/Generated`.
2. **Start a sequence:** drag a clip onto the Timeline. This creates a sequence matching the clip's size, frame rate and SDR/HDR color space. You can also choose **Sequence ▸ New Sequence…** (⌥⌘N) or right-click a clip ▸ **New Sequence from Clip**.
3. **Edit:**
   - Double-click a clip to open it in the Source monitor and mark I/O.
   - Press `,` to Insert or `.` to Overwrite at the playhead on the targeted tracks (the blue track names).
   - Drag clips on the timeline to move them, and drag clip edges to trim.
4. **Play:** press Space or J/K/L with the Timeline or Program monitor active.
5. **Export:** choose **File ▸ Export ▸ Media…** (⇧⌘E), pick a preset, and choose Entire Sequence or In to Out, the frame size, the frame rate and the bitrate. Exporting faster than your footage (for example 120 fps from 30 fps clips) repeats frames; the sheet warns you when that happens.

### Make targets

| Command | What it does |
|---|---|
| `make run` | Build Debug and launch |
| `make build` | Build Debug |
| `make test` | Run all unit tests (`swift test`) |
| `make smoke` | Launch the app with generated media and check import, playback, rendering and undo |
| `make release` | Build the Release app |
| `make dmg` | Package the Release app as `build/Splicewright.dmg` |
| `make fixtures` | Generate sample SDR/HDR clips in `TestMedia/Generated` (no extra tools needed) |
| `make fixtures-ffmpeg` | Generate 4K SDR/HDR clips with `ffmpeg` |
| `make doctor` | Check build prerequisites |
| `make generate` | Regenerate the Xcode project from `project.yml` (maintainers) |

### Prebuilt app

You don't need Xcode to try Splicewright. Download `Splicewright.dmg` from the [Releases page](https://github.com/Panagiotis1226/Splicewright/releases). It's an Apple silicon build for macOS 15 or later. Every green CI run also attaches a `Splicewright-<commit>` `.dmg` artifact; you need to be signed in to GitHub to download it.

1. Open the `.dmg` and drag Splicewright to Applications.
2. The build isn't notarized yet, so macOS blocks the first launch. Open the app once, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway**. Alternatively, run `xattr -dr com.apple.quarantine /Applications/Splicewright.app`.

Notarized builds need a paid Apple Developer account and are planned for M8. To publish a release, change `VERSION` or push a `v*` tag; CI builds the `.dmg` and creates the release. Versions with a `-`, such as `0.3.0-alpha`, are published as pre-releases.

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
| `,` / `.` | Insert / Overwrite the Source clip at the playhead |
| `;` / `'` | Lift / Extract the sequence In–Out range |
| ↑ / ↓ | Previous / next edit point |
| Delete / ⇧Delete (or ⌥Delete) | Delete / ripple delete selected clips |
| ⌘K / ⇧⌘K | Add edit on targeted tracks / all tracks |
| = / - / \\ | Zoom timeline in / out / to fit |
| S | Toggle snapping |
| V A B N R C Y U P H Z T | Tools (Selection, Track Select, Ripple, Rolling, Rate Stretch, Razor, Slip, Slide, Pen, Hand, Zoom, Type) |
| ⌘I | Import |
| ⇧⌘E | Export media |
| ⌘B | New bin |

These are the defaults. To change them, open **Splicewright ▸ Settings… ▸ Keyboard** (⌘,), or choose **Help ▸ Keyboard Shortcuts…**. The editor won't assign a shortcut macOS uses, such as ⌘M (Minimize), ⌘H (Hide) or ⌘Q, so Export Media is ⇧⌘E instead of Premiere's ⌘M. Your shortcuts apply to every project.

Transport keys apply to the active panel, which is outlined in blue. Click a panel to activate it: the Source and Project panels drive the Source monitor, and the Timeline and Program panels drive the sequence.

On the timeline:

- **Selection tool (V):** drag clip edges to trim, or drag a clip to move it (it overwrites where it lands). Hold ⌘ while dropping from the Project panel to insert instead.
- **Ripple Edit (B):** trim a clip edge and ripple everything after it.
- **Rolling Edit (N):** move the cut point between two clips.
- **Slip (Y) and Slide (U):** drag a clip.
- **Razor (C):** click to cut. Hold ⌥ to cut only that track.
- **Track headers:** toggle source targeting, lock, sync lock, and eye/mute/solo. Right-click a header to add or delete tracks.

## Project layout

```
App/                         App entry point and Info.plist
Packages/SplicewrightKit/
  Sources/SWCore/            Pure Swift model: time, timecode, media metadata, project, key map
  Sources/SWCore/Timeline/   Sequences, tracks, clips and every edit operation (pure, tested)
  Sources/SWMedia/           AVFoundation: probing, import, thumbnails, waveforms
  Sources/SWPlayback/        Composition builder, Metal compositor (SDR/HLG/PQ), playback engine
  Sources/SWUI/              SwiftUI/AppKit workspace, timeline canvas, panels
  Tests/SWCoreTests/         Swift Testing; also runs on Linux
  Tests/SWMediaTests/        XCTest: probing, import, waveforms, thumbnails
  Tests/SWPlaybackTests/     XCTest: renders frames through the compositor and checks pixels
  Tests/SWTestSupport/       Synthesizes test clips with AVAssetWriter
  Tools/sw-fixtures/         Writes sample clips (make fixtures, smoke test)
scripts/smoke-test.sh        Drives the real app end to end (CI runs it)
project.yml                  XcodeGen spec (the generated .xcodeproj is committed)
docs/PLAN.md                 Architecture and milestones
```

`SWCore` imports only Foundation, so the editing model can be tested anywhere. Run `swift test --package-path Packages/SplicewrightKit` on Linux and only the SWCore tests run.

## Format support (v1 target)

| | Import | Export |
|---|---|---|
| H.264 | 8-bit SDR up to 4K60 | SDR Rec.709 |
| HEVC | 8/10-bit SDR, HLG, PQ; iPhone Dolby Vision is read as HLG | Main (SDR), Main10 (HLG, PQ) |
| ProRes | 422 Proxy/LT/422/HQ, 4444 | 422 HQ (in the sequence color space) |
| Containers | .mov, .mp4, .m4v; audio .wav .aif .caf .m4a .mp3 | .mov, .mp4 |
