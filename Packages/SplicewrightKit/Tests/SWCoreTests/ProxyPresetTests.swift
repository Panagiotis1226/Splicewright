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

    @Test func tagsAreDistinct() {
        let tags = ProxyPreset.Resolution.allCases.flatMap { resolution in
            ProxyPreset.Codec.allCases.map { ProxyPreset(resolution: resolution, codec: $0).tag }
        }
        #expect(Set(tags).count == tags.count)
    }
}
