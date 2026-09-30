// Writes a small set of synthetic clips for trying the app or for the smoke test:
//   swift run --package-path Packages/SplicewrightKit sw-fixtures <output-directory>
import Foundation
import SWTestSupport

let output = CommandLine.arguments.dropFirst().first ?? "TestMedia/Generated"
let directory = URL(fileURLWithPath: output, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func move(_ url: URL?, to name: String) throws {
    guard let url else {
        print("  skipped \(name): encoder unavailable")
        return
    }
    let destination = directory.appending(path: name)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: url, to: destination)
    print("  \(name)")
}

print("Writing fixtures to \(directory.path)")
try move(try await FixtureWriter.writeVideo(FixtureWriter.h264SDR30(frames: 90), name: "A.mov"),
         to: "A - H.264 SDR 1080p30 ramp.mov")
try move(try await FixtureWriter.writeVideo(FixtureWriter.h264SDR30(frames: 60, fill: .grey(0.8, tenBit: false)), name: "B.mov"),
         to: "B - H.264 SDR 1080p30 light grey.mov")
try move(try await FixtureWriter.writeVideo(FixtureWriter.hevcHLG(fps5994: 60, width: 1920, height: 1080,
                                                                   fill: .grey(0.75, tenBit: true)), name: "C.mov"),
         to: "C - HEVC 10-bit HLG 1080p59.94 reference white.mov")
try move(try await FixtureWriter.writeVideo(FixtureWriter.h264SDR30(frames: 45, width: 1440, height: 1080,
                                                                    fill: .grey(0.5, tenBit: false)), name: "D.mov"),
         to: "D - H.264 SDR 4x3 pillarbox.mov")
try move(try FixtureWriter.writeSine(name: "tone.caf", seconds: 4, amplitude: 0.5), to: "E - Tone 440 Hz.caf")
print("Done.")
