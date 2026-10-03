import AVFoundation
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia

/// Scene Edit Detection's reader on a real file: grey for a second, then a hard cut to a strong color.
final class SceneScanTests: XCTestCase {
    func testFindsTheCutInAFile() async throws {
        var spec = FixtureWriter.h264SDR30(frames: 60, width: 320, height: 180, fill: .grey(0.3, tenBit: false))
        spec.cut = (30, FixtureWriter.Fill(y: 150, cb: 60, cr: 200))
        guard let url = try await FixtureWriter.writeVideo(spec, name: "scene-cut.mov") else {
            throw XCTSkip("No H.264 encoder")
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1))
        let cuts = try await SceneScan.cuts(in: url, range: range, settings: SceneSettings())
        XCTAssertEqual(cuts.count, 1, "\(cuts.map(\.seconds))")
        XCTAssertEqual(cuts.first?.seconds ?? 0, 1, accuracy: 0.04)

        // Only the part of the file asked for is read: the second half has no cut.
        let after = CMTimeRange(start: CMTime(value: 11, timescale: 10), duration: CMTime(value: 9, timescale: 10))
        let none = try await SceneScan.cuts(in: url, range: after, settings: SceneSettings())
        XCTAssertEqual(none, [])
    }
}
