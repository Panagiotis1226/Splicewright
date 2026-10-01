# Splicewright

A native macOS video editor for Apple silicon, laid out like Premiere Pro. It handles SDR (Rec.709) and HDR (HLG, PQ) footage in H.264, HEVC and ProRes, in `.mov` and `.mp4`, up to 4K60.

Status: **M18**. You can:

- import media into bins and check its format details
- mark In/Out in the Source monitor
- edit on a multi-track timeline, with Insert/Overwrite, ripple and rolling trims, slip, slide, razor and ripple delete
- play the sequence in the Program monitor through a Metal compositor that handles SDR and HDR (HLG/PQ), with an optional clipping overlay
- override how a clip's color is read (right-click ▸ Interpret Footage)
- add transitions (cross dissolve, dip to black/white, film dissolve, wipes, audio crossfades) and titles
- apply video effects (Crop, Gaussian Blur, Drop Shadow, Sharpen, Flip, Mirror) with keyframes, and adjustment layers that apply effects to everything below them
- color grade with Color Correction (exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, saturation, vibrance and RGB curves) and `.cube` LUTs, such as a camera's log-to-Rec.709 conversion
- mask clips and effects with ellipse, rectangle or Pen masks (feather, opacity, expansion, add/subtract, inverted, animated paths), to cut out part of a picture or limit a blur or a grade to it
- mix audio in the Audio Track Mixer (track faders, pan, mute/solo, a Mix fader, live meters), apply audio effects (Parametric EQ, Compressor, Hard Limiter), and normalize exports to -14, -16 or -23 LUFS
- animate Position, Scale, Rotation, Anchor Point, Opacity and Volume with keyframes in Effect Controls, shape the curves with Bezier handles in a value graph, see and drag keyframes and Opacity/Volume lines on the timeline, or move, scale and rotate clips directly in the Program monitor
- make HEVC, H.264 or ProRes proxies for smooth editing of 4K/HDR footage (export always uses the originals)
- copy and paste clips and Paste Attributes between them
- recover from crashes with auto-saved versions, and relink moved or missing files (Link Media)
- bring timelines in from Premiere Pro, DaVinci Resolve (free or Studio) and Final Cut Pro, and send them back (FCP7 XML, FCPXML, OpenTimelineIO)
- mark the timeline with colored, named markers and export them as YouTube chapters or chapter marks
- change clip speed (Speed/Duration, Rate Stretch, Reverse) and ramp it with Time Remapping keyframes
- transcribe speech into an editable subtitle track (on-device, nothing uploaded), then burn it in or export .srt/.vtt
- see and delete cached files (Settings ▸ Media Cache)
- switch between workspaces and save your own (Window ▸ Workspaces); layout changes are remembered
- export to H.264, HEVC, HEVC 10-bit HLG/PQ or ProRes (422 HQ, 422, LT, Proxy) at 480p up to 4K and 23.976 up to 120 fps, with a quality preset or a custom bitrate, and tone-map HDR sequences to SDR deliverables

See [docs/PLAN.md](docs/PLAN.md) for the roadmap.

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
    - **Monitor background:** the colored square in the Program monitor's bar (also **View ▸ Program Monitor Background…** or right-click the monitor) sets the color around the video frame: a preset or any color. **Outline the Frame** draws a thin line around it. When you move a clip, the frame's black and the background stay distinct, whatever the frame's size or orientation. The background is only for viewing and is never exported.
5. **Transitions:** drag one from the **Effects** panel onto a cut (or a clip's free edge for a fade), or press ⌘D (video) / ⇧⌘D (audio) to apply the default at the edit point nearest the playhead. Drag a transition's edge to change its length; select it to edit it in **Effect Controls**.
6. **Titles:** choose **Graphics ▸ New Title** (⇧⌘T), drag **Title** from the Effects panel onto a video track, or pick the Type tool (T) and click the Program monitor. Edit the text, font, colors, stroke, shadow, box and position in **Effect Controls**.
7. **Proxies:** select clips in the Project panel, right-click ▸ **Proxy ▸ Create Proxies**, then turn on the **P** button on either monitor (or **View ▸ Use Proxies**). Proxies are HEVC at 1080p by default (about 2.7 GB per hour of 4K30, versus about 20 GB for ProRes 422 Proxy, which scrubs most smoothly); change it in Settings ▸ Media. They are stored in `~/Library/Application Support/Splicewright/Proxies`.
8. **Keyframes:** select a clip and open **Effect Controls**. Each property has a stopwatch: click it to start animating, and a keyframe is added at the playhead. Move the playhead and change the value (drag the number left/right, ⇧ for bigger steps, ⌥ for finer, or click it and type) to add the next keyframe. The ◀ ◆ ▶ buttons jump between keyframes and add or remove one. In the lane on the right, drag a keyframe to move it, ⇧-click to select several, right-click for Linear, Bezier, Auto Bezier, Continuous Bezier, Ease In/Out or Hold, and press Delete to remove the selected ones.
    - **On the timeline:** clips show their keyframes at the frames they're on (diamonds on the line for Opacity on video clips and Volume on audio clips, small marks along the bottom for everything else). The line is Opacity or Volume over time: drag it up or down to change the level (keyframes and all), ⌘-click it or click it with the Pen tool (P) to add a keyframe, drag a diamond to move it in time and value (⇧ keeps its time; it snaps to the playhead), ⇧-click to select several, Delete to remove them, and right-click one for its interpolation. Hide or show them with the wrench menu in the Timeline, **View ▸ Show Video/Audio Keyframes**, or by right-clicking an empty part of a track.
    - **Graph editor:** click the ▸ arrow at the start of a keyframed row to open its value graph (X and Y in two colors for Position). Drag a keyframe point to change its time and value (⇧ keeps the time). Select a keyframe to show its Bezier handles: drag one to shape the curve (how steeply it leaves or arrives, and how far the pull reaches). An Auto Bezier keyframe then becomes Continuous Bezier, with both sides moving together; ⌥-drag a handle to move it on its own (Bezier) for a sharp change of direction. Speed keyframes use the same curves, so Time Remapping ramps smoothly.
    - **In the Program monitor:** with the Selection tool, the selected clip shows its box: drag inside it to move, drag a corner to scale, and drag outside it to rotate (⇧ snaps to 15°). Position and Anchor Point are in sequence pixels from the top left, as in Premiere. Audio clips show Volume (dB).
9. **Copy and paste:** with the Timeline active, ⌘C / ⌘X / ⌘V copy, cut and paste clips at the playhead on the targeted tracks (also between projects). **Edit ▸ Paste Attributes** (⌥⌘V) copies the copied clip's motion, opacity and volume, keyframes included, onto the selected clips.
10. **Missing files:** clips whose file has moved show a red **Media Offline** frame. Right-click the clip in the Project panel ▸ **Link Media…** (or **File ▸ Link Media…**) and pick the file. Other missing files with the same name in that folder and its subfolders are linked too. Files changed on disk by another app are re-read automatically.
11. **Auto-save:** a copy of each changed project is saved every 5 minutes to `~/Library/Application Support/Splicewright/Auto-Save` (Settings ▸ General sets how often and how many are kept). After a crash, Splicewright offers to open the latest ones; **File ▸ Open Auto-Save…** opens any of them. Logs are in `~/Library/Logs/Splicewright` (**Help ▸ Show Logs in Finder**).
12. **Captions:** choose **Sequence ▸ Transcribe & Create Captions…**, pick the language and a style (Standard: two lines at the bottom; Social: big, one line), and Splicewright transcribes the sequence's audio on your Mac into a subtitle track above the video tracks. macOS 26 uses Apple's SpeechAnalyzer; macOS 15 uses the older on-device recognizer and asks for Speech Recognition permission. The first use of a language may download it.
    - On the timeline, drag a caption to move it, drag its edges to trim, cut it with the Razor (C), press Delete to remove it, and double-click it to edit the text.
    - The **Captions** panel (next to Effect Controls) lists every caption: click a time to jump there, edit text (⏎ saves, ⌥⏎ adds a line), right-click to split at the playhead or merge with the next one, and use Find / Replace All to fix a name everywhere.
    - The ⋯ menu changes the style (re-splitting the lines), imports an existing .srt/.vtt, or exports one. The eye in the track header hides a track.
    - In **Export Media**, choose a track to **Burn In** and/or a **Caption File** (.srt or .vtt, written next to the video and timed to the exported range).
13. **Speed:** select clips and choose **Clip ▸ Speed/Duration…** (⌘R). Set a speed (1%-10000%) or a duration; the clip keeps the source it plays, so its length follows. Reverse Speed plays it backwards; Maintain Audio Pitch keeps voices natural; Ripple Edit shifts later clips instead of stopping at the next one. The **Rate Stretch** tool (R) changes speed by dragging a clip's edge. Clips show their speed after their name, e.g. `[200%]` or `[-100%]`.
    - **Time Remapping:** in Effect Controls, click the **Speed** stopwatch and add keyframes. Speed ramps between them (Ease for smooth ramps), 0% holds a frame, and the clip keeps its length.
    - Reversed and time-remapped clips play their video only; their audio is silent in this version.
14. **Markers:** press **M** to add a marker at the playhead (M again on it opens it), **⇧M** / **⌘⇧M** to jump to the next or previous one. Drag a marker in the ruler to move it, double-click it to name it, add notes, a color, a duration, or flag it as a chapter. The **Markers** panel lists them all (filter by color, click to jump). In the Source monitor, M adds a clip marker that shows on every clip using that part of the file. **File ▸ Export ▸ Markers as YouTube Chapters…** copies `0:00 Intro` lines for the video description (YouTube needs 3+ chapters, 10 s apart); exports also embed chapter marks that QuickTime and VLC show.
15. **Effects:** drag a video effect from the **Effects** panel onto a clip (onto any selected clip to apply it to all of them), or select clips and double-click the effect. Each effect shows in **Effect Controls** under Motion and Opacity, with a stopwatch on every value: **fx** turns it off, the arrows change the order they apply in, and ↶ resets it. Clips with effects show `fx` on the timeline. With Crop applied, drag the handles on the crop's edges in the Program monitor.
    - **Color:** **Color Correction** has Exposure (in stops), Contrast, Highlights, Shadows, Whites, Blacks, Temperature, Tint, Saturation and Vibrance, all keyframeable, plus **RGB Curves** (click to add a point, drag it, double-click to remove it; RGB, Red, Green and Blue tabs). The **LUT** effect applies a `.cube` file (1D or 3D) with an Intensity: click **Choose** and pick one, or a recent one from the same menu. For log footage, use the LUT from your camera's maker (S-Log3, V-Log, C-Log, Log C…) to convert to Rec.709, then grade on top. A LUT whose file goes missing shows a warning, and the clip plays without it until you find it. Put Color Correction or a LUT on an adjustment layer to grade everything below it.
    - **Masks:** under **Opacity** and under each Blur, Sharpen, Drop Shadow, Color Correction or LUT effect, click the ellipse or rectangle button to add a mask, or the pen to draw one: click in the Program monitor to place points, drag while placing to curve them, and click the first point to close it. A mask on Opacity shows only what's inside it; a mask on an effect applies the effect only there (blur a face, brighten a sky). Click a mask's name to show its path in the Program monitor: drag a point or its handles (⌥ moves one handle on its own), drag inside to move the whole mask, click the path to add a point, ⌘-click a point to delete it and ⌥-click to switch between a corner and a curve. Each mask has Feather, Opacity and Expansion (all keyframeable), Add or Subtract, and Inverted. Click the **Mask Path** stopwatch to animate the shape: each change at a new time adds a keyframe, and the path follows the clip's motion. Masks, Crop and Flip work on the picture as you see it, portrait phone video included.
    - **Adjustment layers:** choose **Graphics ▸ New Adjustment Layer** or drag **Adjustment Layer** from the Effects panel onto a video track. Its effects apply to every track below it for as long as it lasts; tracks above it aren't affected. Lower its Opacity to blend the result with the original. Trim and move it like any clip.
16. **Audio mixing:** the **Audio Track Mixer** tab sits next to Project. Each audio track has a pan knob (drag up/down), M (mute) and S (solo), a fader (⌥ for fine control) and a meter with peak hold. The Mix strip on the right sets the overall level. Double-click a fader or knob to reset it. Faders change what you hear during playback right away and are saved with the sequence. Audio effects come from the **Effects** panel's Audio Effects section: drag one onto an audio clip and set it in Effect Controls (every value has a stopwatch). The level meters next to the timeline show the real Mix.
17. **Premiere Pro, Resolve and Final Cut timelines:** Splicewright can't open `.prproj` or `.drp` project files (they're closed formats that even those apps can't exchange), but it reads and writes the timeline files they export for exactly this:
    - From **Premiere Pro**: select the sequence, **File ▸ Export ▸ Final Cut Pro XML…**
    - From **DaVinci Resolve** (free or Studio): right-click the timeline ▸ **Timelines ▸ Export ▸ FCPXML**, **XML** or **OpenTimelineIO** (or File ▸ Export ▸ Timeline…).
    - From **Final Cut Pro**: **File ▸ Export XML…**
    - Then in Splicewright: **File ▸ Import Timeline from Premiere Pro, Resolve or Final Cut…** It opens as a new sequence with its clips, source in/out points, tracks, cuts, dissolves and fades, constant speed, opacity, volume and markers. The media is imported from where the timeline says it is; anything not found comes in offline (red), ready for **File ▸ Link Media…**. Effects, titles, color grades and keyframes from the other app don't carry over, the same as between those apps.
    - To go the other way: **File ▸ Export ▸ Timeline for Premiere Pro (Final Cut Pro 7 XML)…**, **…for DaVinci Resolve or Final Cut Pro (FCPXML)…** or **…for DaVinci Resolve (OpenTimelineIO)…**, then import that file there.
18. **Export:** choose **File ▸ Export ▸ Media…** (⇧⌘E), pick a preset, and choose Entire Sequence or In to Out, the frame size, the frame rate and the bitrate. Exporting faster than your footage (for example 120 fps from 30 fps clips) repeats frames; the sheet warns you when that happens. **Normalize Loudness** measures the mix first, then sets it to -14 LUFS (YouTube, Spotify), -16 (Apple Podcasts) or -23 (EBU R128), limiting peaks under -1 dBTP when needed; the finished sheet shows the before and after.

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
2. The build isn't notarized (that needs a paid Apple Developer account), so macOS blocks the first launch. Open the app once, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway**. Alternatively, run `xattr -dr com.apple.quarantine /Applications/Splicewright.app`.

To publish a release, change `VERSION` or push a `v*` tag; CI builds the `.dmg` and creates the release. Versions with a `-`, such as `0.3.0-alpha`, are published as pre-releases.

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
| ⌘D / ⇧⌘D | Apply the default video / audio transition |
| ⇧⌘T | New title |
| ⌘C / ⌘X / ⌘V | Copy / cut / paste clips (Timeline active) |
| ⌥⌘V | Paste Attributes |
| ⌘R | Speed/Duration |
| M / ⇧M / ⌘⇧M | Add marker / next marker / previous marker |
| = / - / \\ | Zoom timeline in / out / to fit |
| S | Toggle snapping |
| V A B N R C Y U P H Z T | Tools (Selection, Track Select, Ripple, Rolling, Rate Stretch, Razor, Slip, Slide, Pen, Hand, Zoom, Type) |
| ⌘I | Import |
| ⇧⌘E | Export media |
| ⌘B | New bin |

**Workspaces.** Window ▸ Workspaces switches between Editing, Assembly (big Project panel with thumbnails), Effects and Review (big Program monitor), or ⌥⇧1…9. Panel sizes, the front tab, Project view and thumbnail size, timeline zoom, monitor options and the window's size and position are saved to the current workspace as you change them. **Save as New Workspace…** keeps a layout of your own; **Reset to Saved Layout** undoes unsaved changes.

**Cache.** Thumbnails and waveforms are cached in `~/Library/Caches/com.splicewright.Splicewright`, proxies in Application Support. Settings ▸ Media Cache shows how much each uses and deletes all of it, chosen categories, individual proxies, or files older than a number of days.

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
