import AVFoundation
import XCTest
@testable import SWExport

/// The loudness pass reads, and the encode pass rewrites, the export reader's audio. A reader's
/// buffer can hold its data in more than one piece; every piece has to be read and written.
final class InterleavedAudioTests: XCTestCase {
    /// Interleaved stereo float samples, in a block buffer made of two separate pieces.
    private func splitSample(_ values: [Float]) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: nil, capacity: 2, flags: 0, blockBufferOut: &block), noErr)
        let whole = try XCTUnwrap(block)
        let half = values.count / 2
        for part in [Array(values[..<half]), Array(values[half...])] {
            let bytes = part.count * MemoryLayout<Float>.size
            var piece: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &piece), noErr)
            let made = try XCTUnwrap(piece)
            let copied = part.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: made, offsetIntoDestination: 0,
                                              dataLength: bytes)
            }
            XCTAssertEqual(copied, noErr)
            XCTAssertEqual(CMBlockBufferAppendBufferReference(whole, targetBBuf: made, offsetToData: 0, dataLength: bytes,
                                                              flags: 0), noErr)
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                                      magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                      formatDescriptionOut: &format), noErr)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: whole, formatDescription: try XCTUnwrap(format), sampleCount: values.count / 2,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testBuffersInSeveralPiecesAreReadAndWrittenWhole() throws {
        let frames = 256
        let values = (0..<frames).flatMap { [Float($0), -Float($0)] }
        let sample = try splitSample(values)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        XCTAssertFalse(CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: values.count * 4),
                       "the data really is in two pieces")

        var read: [[Float]] = []
        InterleavedAudio.withChannels(of: sample) { read = $0 }
        XCTAssertEqual(read.first, (0..<frames).map(Float.init))
        XCTAssertEqual(read.last, (0..<frames).map { -Float($0) })

        InterleavedAudio.modifyChannels(of: sample) { channels in
            for index in channels.indices { channels[index] = channels[index].map { $0 * 2 } }
        }
        InterleavedAudio.withChannels(of: sample) { read = $0 }
        XCTAssertEqual(read.first, (0..<frames).map { Float($0) * 2 }, "both pieces were written back")
    }
}
