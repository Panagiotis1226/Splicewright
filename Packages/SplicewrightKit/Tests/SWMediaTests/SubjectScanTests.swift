import AVFoundation
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia

/// Auto Reframe's subject finder on a real file: samples cover the range asked for and stay in
/// the picture (a flat grey frame has no face or person to find).
final class SubjectScanTests: XCTestCase {
    func testSamplesTheRangeInsideThePicture() async throws {
        let spec = FixtureWriter.h264SDR30(frames: 60, width: 320, height: 180, fill: .grey(0.5, tenBit: false))
        guard let url = try await FixtureWriter.writeVideo(spec, name: "subject-grey.mov") else {
            throw XCTSkip("No H.264 encoder")
        }
        let samples = try await SubjectScan.path(in: url, from: 0.5, to: 1.5, interval: 0.25)
        XCTAssertEqual(samples.map(\.time), [0.5, 0.75, 1, 1.25, 1.5])
        for sample in samples {
            XCTAssertTrue((0...1).contains(sample.x) && (0...1).contains(sample.y), "\(sample)")
            XCTAssertLessThan(sample.confidence, 0.9, "no face in a grey frame")
        }
    }
}
