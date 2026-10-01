import Foundation
import Metal
import SWCore

/// Color Correction's values for one frame, -1...1 except exposure (stops) and saturation (1 = as shot).
struct ColorGrade: Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 1
    var vibrance: Double = 0

    init(_ effect: ResolvedEffect) {
        exposure = effect["exposure"]
        contrast = effect["contrast"] / 100
        highlights = effect["highlights"] / 100
        shadows = effect["shadows"] / 100
        whites = effect["whites"] / 100
        blacks = effect["blacks"] / 100
        temperature = effect["temperature"] / 100
        tint = effect["tint"] / 100
        saturation = effect.values["saturation"].map { $0 / 100 } ?? 1
        vibrance = effect["vibrance"] / 100
    }

    var isNeutral: Bool {
        [exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance].allSatisfy { $0 == 0 }
            && saturation == 1
    }

    var uniforms: ColorUniforms {
        ColorUniforms(a: SIMD4(Float(exposure), Float(contrast), Float(highlights), Float(shadows)),
                      b: SIMD4(Float(whites), Float(blacks), Float(temperature), Float(tint)),
                      c: SIMD4(Float(saturation), Float(vibrance), 0, 0))
    }
}

/// Must match `ColorUniforms` in Shaders.swift.
struct ColorUniforms {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
}

/// Must match `LUTUniforms` in Shaders.swift.
struct LUTUniforms {
    var domainMin: SIMD4<Float>
    var domainMax: SIMD4<Float>
}

/// LUT and curve textures, made once and reused while their source doesn't change.
final class ColorResources: @unchecked Sendable {
    struct LUTTexture {
        var texture: MTLTexture
        var lut: CubeLUT
        var modified: Date?
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var luts: [String: LUTTexture] = [:]
    private var failed: Set<String> = []
    private var curves: [ColorCurves: MTLTexture] = [:]

    init(device: MTLDevice) { self.device = device }

    /// The LUT at `path`, reloaded when the file changes; nil if it's missing or unreadable.
    func lut(at path: String) -> LUTTexture? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        if let cached = luts[path], cached.modified == modified { return cached }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            if failed.insert(path).inserted { AppLog.shared.warning("LUT not found: \(path)", category: "color") }
            return nil
        }
        do {
            let lut = try CubeLUT(parsing: text)
            guard let texture = makeTexture(lut) else { return nil }
            let entry = LUTTexture(texture: texture, lut: lut, modified: modified)
            luts[path] = entry
            failed.remove(path)
            return entry
        } catch let error as CubeLUT.ParseError {
            if failed.insert(path).inserted { AppLog.shared.warning("LUT \(path): \(error.message)", category: "color") }
            return nil
        } catch {
            return nil
        }
    }

    private func makeTexture(_ lut: CubeLUT) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = .rgba32Float
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        if lut.is3D {
            descriptor.textureType = .type3D
            descriptor.width = lut.size
            descriptor.height = lut.size
            descriptor.depth = lut.size
        } else {
            descriptor.textureType = .type2D
            descriptor.width = lut.size
            descriptor.height = 1
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // RGB triples to RGBA, red fastest (the .cube order is Metal's x, y, z order too).
        var rgba = [Float](repeating: 1, count: lut.values.count / 3 * 4)
        for index in 0..<(lut.values.count / 3) {
            rgba[index * 4] = lut.values[index * 3]
            rgba[index * 4 + 1] = lut.values[index * 3 + 1]
            rgba[index * 4 + 2] = lut.values[index * 3 + 2]
        }
        let rowBytes = lut.size * 16
        rgba.withUnsafeBytes { raw in
            if lut.is3D {
                texture.replace(region: MTLRegionMake3D(0, 0, 0, lut.size, lut.size, lut.size), mipmapLevel: 0, slice: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: rowBytes, bytesPerImage: rowBytes * lut.size)
            } else {
                texture.replace(region: MTLRegionMake2D(0, 0, lut.size, 1), mipmapLevel: 0, withBytes: raw.baseAddress!,
                                bytesPerRow: rowBytes)
            }
        }
        return texture
    }

    /// A 256 × 3 table of the curves (rows: red, green, blue, each through the master curve).
    func curvesTexture(_ value: ColorCurves) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = curves[value] { return cached }
        let samples = 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: samples, height: 3,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let table = value.table(samples: samples)
        table.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, samples, 3), mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: samples * 4)
        }
        if curves.count > 64 { curves.removeAll() }
        curves[value] = texture
        return texture
    }
}

extension MetalRenderer {
    /// Color Correction, curves or a LUT on `input`, into `output`. Returns false when there was
    /// nothing to do (a missing LUT file, say), so the caller keeps the input.
    func runColor(_ effect: PixelEffect, on input: MTLTexture, into output: MTLTexture,
                  commandBuffer: MTLCommandBuffer) throws -> Bool {
        switch effect {
        case .color(let grade):
            var uniforms = grade.uniforms
            try pass(colorPipeline, into: output, textures: [input], commandBuffer: commandBuffer, bytes: &uniforms)
            return true
        case .curves(let curves):
            guard let table = colorResources.curvesTexture(curves) else { return false }
            var uniforms = EffectUniforms(a: SIMD4(1, 0, 0, 0))
            try pass(curvesPipeline, into: output, textures: [input, table], commandBuffer: commandBuffer, bytes: &uniforms)
            return true
        case .lut(let path, let intensity):
            guard let entry = colorResources.lut(at: path) else { return false }
            let lut = entry.lut
            var uniforms = LUTUniforms(
                domainMin: SIMD4(lut.domainMin[0], lut.domainMin[1], lut.domainMin[2], Float(min(max(intensity, 0), 1))),
                domainMax: SIMD4(lut.domainMax[0], lut.domainMax[1], lut.domainMax[2], Float(lut.size)))
            try pass(lut.is3D ? lut3DPipeline : lut1DPipeline, into: output, textures: [input, entry.texture],
                     commandBuffer: commandBuffer, bytes: &uniforms)
            return true
        default:
            return false
        }
    }
}
