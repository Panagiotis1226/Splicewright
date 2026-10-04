import Foundation
import Metal
import SWMedia

/// Still images as textures (premultiplied sRGB RGBA8), loaded once per file and kept for the
/// most recently drawn ones. Big photos are read at up to 4096 pixels on their long side.
final class StillTextureCache: @unchecked Sendable {
    static let maxPixels = 4096

    private let device: MTLDevice
    private let lock = NSLock()
    private var cache: [URL: MTLTexture] = [:]
    private var order: [URL] = []
    private let capacity = 24

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(for url: URL) -> MTLTexture? {
        lock.lock()
        if let cached = cache[url] {
            order.removeAll { $0 == url }
            order.append(url)
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let texture = makeTexture(url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        cache[url] = texture
        order.append(url)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return texture
    }

    private func makeTexture(_ url: URL) -> MTLTexture? {
        guard let (pixels, width, height) = StillImage.rgba(at: url, maxPixels: Self.maxPixels) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }
}
