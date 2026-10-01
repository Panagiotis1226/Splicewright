import AVFoundation
import CoreMedia
import SWCore

/// Chapter marks as Apple players read them: a disabled 3GPP (tx3g) text track, one sample per
/// chapter, that the video track points to as its chapter list.
struct ChapterTrack: @unchecked Sendable {
    let input: AVAssetWriterInput
    let samples: [CMSampleBuffer]

    init?(_ chapters: [Chapters.Chapter], range: CMTimeRange, writer: AVAssetWriter, video: AVAssetWriterInput) {
        guard !chapters.isEmpty, let format = Self.format() else { return nil }
        let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        input.marksOutputTrackAsEnabled = false
        input.languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        guard writer.canAdd(input) else {
            AppLog.shared.warning("Export: the writer can't take a chapter track; no chapters", category: "export")
            return nil
        }
        writer.add(input)
        guard video.canAddTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        else {
            AppLog.shared.warning("Export: the video track can't reference a chapter track; no chapters",
                                   category: "export")
            input.markAsFinished()
            return nil
        }
        video.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        let samples = chapters.enumerated().compactMap { index, chapter -> CMSampleBuffer? in
            let start = range.start + CMTime(seconds: chapter.seconds, preferredTimescale: 600)
            let end = index + 1 < chapters.count
                ? range.start + CMTime(seconds: chapters[index + 1].seconds, preferredTimescale: 600) : range.end
            let safeEnd = max(end, start + CMTime(value: 1, timescale: 600))
            return Self.sample(chapter.title, timeRange: CMTimeRange(start: start, end: safeEnd), format: format)
        }
        self.input = input
        self.samples = samples
    }

    /// A plain tx3g description: one sans-serif font, white on clear (chapters aren't drawn).
    private static func format() -> CMFormatDescription? {
        let white: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
            kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
        ]
        let clear: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
            kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 0,
        ]
        let box: [CFString: Any] = [
            kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
            kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
        ]
        let style: [CFString: Any] = [
            kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
            kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
            kCMTextFormatDescriptionStyle_ForegroundColor: white, kCMTextFormatDescriptionStyle_FontSize: 18,
        ]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: clear,
            kCMTextFormatDescriptionExtension_DefaultTextBox: box,
            kCMTextFormatDescriptionExtension_DefaultStyle: style,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text,
                                               mediaSubType: kCMTextFormatType_3GText,
                                               extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    /// One text sample: a big-endian UTF-8 length, the title, and an `encd` box saying it's UTF-8.
    private static func sample(_ title: String, timeRange: CMTimeRange, format: CMFormatDescription) -> CMSampleBuffer? {
        let text = Array(title.utf8.prefix(Int(UInt16.max) - 64))
        var bytes = [UInt8(text.count >> 8), UInt8(text.count & 0xff)] + text
        bytes += [0, 0, 0, 12, 0x65, 0x6E, 0x63, 0x64, 0, 0, 1, 0]
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: raw.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: timeRange.duration, presentationTimeStamp: timeRange.start,
                                        decodeTimeStamp: .invalid)
        var size = bytes.count
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                             sampleBufferOut: &buffer)
        return buffer
    }
}
