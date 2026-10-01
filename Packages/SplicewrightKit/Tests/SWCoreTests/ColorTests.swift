import Foundation
import Testing
@testable import SWCore

@Suite("Color correction, curves and LUTs")
struct ColorTests {
    private func cube3D(size: Int, title: String = "Test", _ transform: ([Float]) -> [Float]) -> String {
        var lines = ["# made in a test", "TITLE \"\(title)\"", "LUT_3D_SIZE \(size)", ""]
        let n = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = transform([Float(r) / n, Float(g) / n, Float(b) / n])
                    lines.append(out.map { String(format: "%.6f", $0) }.joined(separator: " "))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func parses3DCubesAndAppliesThem() throws {
        let identity = try CubeLUT(parsing: cube3D(size: 17) { $0 })
        #expect(identity.title == "Test" && identity.size == 17 && identity.is3D)
        let sample: [Float] = [0.2, 0.55, 0.9]
        #expect(zip(identity.apply(sample), sample).allSatisfy { abs($0 - $1) < 1e-4 }, "identity stays identity")
        let invert = try CubeLUT(parsing: cube3D(size: 9) { $0.map { 1 - $0 } })
        #expect(zip(invert.apply(sample), sample.map { 1 - $0 }).allSatisfy { abs($0 - $1) < 1e-4 }, "and interpolates")
        #expect(CubeLUT.identity(size: 2).apply([0.3, 0.3, 0.3]) == [0.3, 0.3, 0.3])
    }

    @Test func parses1DCubesAndDomains() throws {
        let text = """
        LUT_1D_SIZE 3
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 2 2 2
        0 0 0
        0.25 0.25 0.25
        1 1 1
        """
        let lut = try CubeLUT(parsing: text)
        #expect(!lut.is3D && lut.domainMax == [2, 2, 2])
        #expect(abs(lut.apply([1, 1, 1])[0] - 0.25) < 1e-6, "1.0 is the middle of a 0-2 domain")
    }

    @Test func rejectsBrokenFiles() {
        #expect(throws: CubeLUT.ParseError.noSize) { try CubeLUT(parsing: "0 0 0\n1 1 1") }
        #expect(throws: CubeLUT.ParseError.wrongCount(expected: 8, found: 1)) {
            try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0")
        }
        #expect(throws: CubeLUT.ParseError.badSize(1)) { try CubeLUT(parsing: "LUT_3D_SIZE 1\n0 0 0") }
        #expect(throws: CubeLUT.ParseError.badLine(2, "0 0")) { try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0") }
    }

    @Test func curvesAreSmoothAndNeverOvershoot() {
        var curves = ColorCurves()
        #expect(curves.isIdentity)
        let straight = curves.table(samples: 5)
        #expect(straight.count == 15 && abs(straight[2] - 0.5) < 1e-6)
        // Lift the midtones of the master curve.
        curves[.rgb] = [.init(0, 0), .init(0.5, 0.65), .init(1, 1)]
        #expect(!curves.isIdentity)
        let lifted = curves.table(samples: 101)
        #expect(abs(lifted[50] - 0.65) < 1e-6, "passes through its point")
        #expect(lifted[0] == 0 && abs(lifted[100] - 1) < 1e-6, "ends stay put")
        #expect(zip(lifted.prefix(101), lifted.prefix(101).dropFirst()).allSatisfy { $0 <= $1 + 1e-6 }, "monotone")
        // A steep S-curve still doesn't overshoot 0...1.
        curves[.red] = [.init(0, 0), .init(0.3, 0.05), .init(0.7, 0.95), .init(1, 1)]
        #expect(curves.table().allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func defaultsAreNoOpsAndSettingsSave() throws {
        var effect = ClipEffect(kind: .colorCorrection)
        #expect(effect.resolved(at: .zero).isNoOp, "a fresh Color Correction changes nothing")
        effect.parameters["exposure"] = AnimatableProperty([1])
        #expect(!effect.resolved(at: .zero).isNoOp)
        var curvesOnly = ClipEffect(kind: .colorCorrection)
        var curves = ColorCurves()
        curves[.blue] = [.init(0, 0.1), .init(1, 1)]
        curvesOnly.curves = curves
        #expect(!curvesOnly.resolved(at: .zero).isNoOp, "curves alone count")

        var lut = ClipEffect(kind: .lut)
        #expect(lut.resolved(at: .zero).isNoOp, "no file chosen yet")
        lut.lutPath = "/Users/me/LUTs/SLog3 to 709.cube"
        #expect(!lut.resolved(at: .zero).isNoOp && lut.resolved(at: .zero).lutPath == lut.lutPath)
        let decoded = try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(curvesOnly))
        #expect(decoded == curvesOnly)
        #expect(EffectKind.video.contains(.colorCorrection) && EffectKind.video.contains(.lut))
    }
}
