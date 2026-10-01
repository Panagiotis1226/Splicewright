import Foundation
import Testing
@testable import SWCore

@Suite("Proxy presets")
struct ProxyPresetTests {
    @Test func sizes() {
        let p1080 = ProxyPreset(resolution: .p1080)
        #expect(p1080.size(width: 3840, height: 2160) == (1920, 1080))
        #expect(p1080.size(width: 2160, height: 3840) == (1080, 1920), "vertical stays vertical")
        #expect(p1080.size(width: 1280, height: 720) == (1280, 720), "never upscaled")
        #expect(ProxyPreset(resolution: .p720).size(width: 4096, height: 2160) == (1366, 720))
        #expect(ProxyPreset(resolution: .half).size(width: 1918, height: 1078) == (960, 540))
    }

    @Test func usefulness() {
        #expect(ProxyPreset.standard.isUseful(width: 3840, height: 2160))
        #expect(!ProxyPreset.standard.isUseful(width: 1920, height: 1080))
        #expect(ProxyPreset(resolution: .half).isUseful(width: 1920, height: 1080))
    }

    @Test func compressedProxiesAreSmallerThanProRes() {
        let hevc = ProxyPreset(codec: .hevc).bytesPerHour(sourceWidth: 3840, sourceHeight: 2160, fps: 30)
        let prores = ProxyPreset(codec: .proRes422Proxy).bytesPerHour(sourceWidth: 3840, sourceHeight: 2160, fps: 30)
        // ~2.7 GB vs ~20 GB per hour at 1080p30.
        #expect((2_000_000_000...3_500_000_000).contains(hevc))
        #expect(prores > hevc * 6)
        #expect(ProxyPreset(codec: .h264).effectiveCodec(sourceIsHDR: true) == .hevc)
        #expect(ProxyPreset(codec: .h264).effectiveCodec(sourceIsHDR: false) == .h264)
        #expect(ProxyPreset.standard.codec == .hevc)
    }

    @Test func tagsAreDistinct() {
        let tags = ProxyPreset.Resolution.allCases.flatMap { resolution in
            ProxyPreset.Codec.allCases.map { ProxyPreset(resolution: resolution, codec: $0).tag }
        }
        #expect(Set(tags).count == tags.count)
    }
}
