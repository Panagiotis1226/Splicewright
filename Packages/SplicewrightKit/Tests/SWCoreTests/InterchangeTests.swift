import Foundation
import Testing
@testable import SWCore

@Suite("Timeline interchange")
struct InterchangeTests {
    private let rate = FrameRate.fps29_97
    private let a = InterchangeMedia(path: "/Volumes/Footage/A Cam.mov", duration: RationalTime(frames: 900, rate: .fps29_97),
                                     width: 1920, height: 1080)
    private let b = InterchangeMedia(path: "/Volumes/Footage/B Cam.mov", duration: RationalTime(frames: 900, rate: .fps29_97),
                                     width: 1920, height: 1080)
    private let music = InterchangeMedia(path: "/Volumes/Footage/Music.wav",
                                         duration: RationalTime(frames: 3000, rate: .fps29_97),
                                         hasVideo: false)

    /// V1: A (0-60) dissolving to B (60-150, 200%); V2: B at 50% opacity (30-90);
    /// A1: A's sound; A2: music at -6 dB; a marker.
    private func sample() -> InterchangeTimeline {
        let clipA = InterchangeClip(name: "A Cam", media: a, start: 0, duration: 60,
                                    sourceStart: RationalTime(frames: 10, rate: rate))
        let clipB = InterchangeClip(name: "B Cam", media: b, start: 60, duration: 90,
                                    sourceStart: RationalTime(frames: 100, rate: rate),
                                    speed: 200)
        let overlay = InterchangeClip(name: "B Cam", media: b, start: 30, duration: 60, sourceStart: .zero, opacity: 0.5)
        let sound = InterchangeClip(name: "A Cam", media: a, start: 0, duration: 60,
                                    sourceStart: RationalTime(frames: 10, rate: rate))
        let bed = InterchangeClip(name: "Music", media: music, start: 0, duration: 150, sourceStart: .zero, gainDB: -6)
        return InterchangeTimeline(
            name: "Edit", width: 1920, height: 1080, rate: rate, videoTracks: [[clipA, clipB], [overlay]],
            audioTracks: [[sound], [bed]],
            transitions: [InterchangeTransition(isAudio: false, track: 0, frame: 60, before: 10, after: 10,
                                                kind: .crossDissolve)],
            markers: [Marker(frame: 45, name: "Beat", comment: "drop")])
    }

    private func expectSameEdit(_ read: InterchangeTimeline, _ format: InterchangeFormat) {
        let original = sample()
        #expect(read.rate == original.rate, "\(format)")
        #expect(read.videoTracks.count >= 2 && read.audioTracks.count >= 2, "\(format)")
        let v1 = read.videoTracks[0]
        #expect(v1.map(\.start) == [0, 60] && v1.map(\.duration) == [60, 90], "\(format): V1 \(v1.map(\.start))")
        #expect(v1.map(\.media?.path) == [a.path, b.path], "\(format)")
        #expect(abs(v1[0].sourceStart.seconds - RationalTime(frames: 10, rate: rate).seconds) < 0.001, "\(format)")
        #expect(abs(v1[1].speed - 200) < 0.5, "\(format): speed \(v1[1].speed)")
        #expect(read.videoTracks[1].map(\.start) == [30], "\(format): V2")
        let music = read.audioTracks.flatMap { $0 }.first { $0.media?.path == self.music.path }
        #expect(music?.duration == 150 && abs((music?.gainDB ?? 0) + 6) < 0.01, "\(format): music")
        #expect(read.audioTracks.flatMap { $0 }.contains { $0.media?.path == a.path && $0.start == 0 }, "\(format): A's sound")
        let dissolve = read.transitions.first { !$0.isAudio }
        #expect(dissolve?.frame == 60 && dissolve?.duration == 20, "\(format): transition \(String(describing: dissolve))")
        #expect(read.markers.map(\.frame) == [45] && read.markers.first?.name == "Beat", "\(format): markers")
    }

    @Test(arguments: InterchangeFormat.allCases)
    func roundTrips(_ format: InterchangeFormat) throws {
        let data = format.write(sample())
        #expect(InterchangeFormat.detect(data) == format)
        let read = try InterchangeFormat.read(data)
        expectSameEdit(read, format)
        #expect(abs((read.videoTracks[1].first?.opacity ?? 1) - 0.5) < 0.01, "\(format): opacity")
    }

    @Test func premiereXMLWithTransitionsAndStereoPairs() throws {
        // As Premiere writes it: -1 at the transition, NTSC rate, the stereo file on two tracks.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4"><project><name>P</name><children><sequence id="sequence-1"><name>Premiere Seq</name>
        <rate><timebase>24</timebase><ntsc>TRUE</ntsc></rate>
        <media><video><format><samplecharacteristics><width>3840</width><height>2160</height></samplecharacteristics></format>
        <track>
          <clipitem id="c1"><name>one</name><start>0</start><end>-1</end><in>0</in><out>48</out>
            <file id="file-1"><name>one.mov</name><pathurl>file://localhost/Users/me/My%20Clips/one.mov</pathurl>
              <rate><timebase>24</timebase><ntsc>TRUE</ntsc></rate><duration>500</duration>
              <media><video/><audio/></media></file></clipitem>
          <transitionitem><start>36</start><end>60</end><alignment>center</alignment>
            <effect><name>Cross Dissolve</name></effect></transitionitem>
          <clipitem id="c2"><name>two</name><start>-1</start><end>96</end><in>24</in><out>72</out><file id="file-1"/></clipitem>
        </track></video>
        <audio>
          <track><clipitem id="a1"><start>0</start><end>48</end><in>0</in><out>48</out><file id="file-1"/>
            <sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>
            <filter><effect><effectid>audiolevels</effectid>
              <parameter><parameterid>level</parameterid><value>0.5</value></parameter></effect></filter>
          </clipitem></track>
          <track><clipitem id="a2"><start>0</start><end>48</end><in>0</in><out>48</out><file id="file-1"/>
            <sourcetrack><mediatype>audio</mediatype><trackindex>2</trackindex></sourcetrack></clipitem></track>
        </audio></media>
        <marker><name>Here</name><comment></comment><in>12</in><out>-1</out></marker>
        </sequence></children></project></xmeml>
        """
        let timeline = try InterchangeFormat.read(Data(xml.utf8))
        #expect(timeline.name == "Premiere Seq" && timeline.rate == .fps23_976)
        #expect(timeline.width == 3840 && timeline.height == 2160)
        #expect(timeline.videoTracks[0].map(\.start) == [0, 48] && timeline.videoTracks[0].map(\.end) == [48, 96],
                "-1 resolves to the transition's centre")
        #expect(timeline.videoTracks[0].first?.media?.path == "/Users/me/My Clips/one.mov")
        #expect(timeline.audioTracks.count == 1 && timeline.audioTracks[0].count == 1, "one stereo clip, not two")
        #expect(abs((timeline.audioTracks[0].first?.gainDB ?? 0) + 6.02) < 0.05)
        #expect(timeline.transitions.first?.frame == 48 && timeline.transitions.first?.duration == 24)
        #expect(timeline.markers.map(\.frame) == [12])
    }

    @Test func resolveFCPXMLWithTimecodeStartAndConnectedClips() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.9"><resources>
          <format id="r0" frameDuration="1/25s" width="1080" height="1920"/>
          <asset id="r1" name="Interview" start="3600s" duration="60s" hasVideo="1" hasAudio="1" format="r0">
            <media-rep kind="original-media" src="file:///Users/me/Interview.mp4"/></asset>
          <asset id="r2" name="Broll" start="0s" duration="20s" hasVideo="1" hasAudio="0" format="r0"
            src="file:///Users/me/Broll.mov"/>
        </resources><library><event name="E"><project name="Vertical Edit">
          <sequence format="r0" tcStart="3600s" duration="10s"><spine>
            <asset-clip ref="r1" offset="3600s" start="3602s" duration="8s" name="Interview">
              <asset-clip ref="r2" lane="1" offset="3604s" start="1s" duration="2s" name="Broll"/>
              <marker start="3603s" duration="1/25s" value="Quote"/>
              <adjust-volume amount="-3dB"/>
            </asset-clip>
            <gap offset="3608s" start="3600s" duration="2s"/>
          </spine></sequence></project></event></library></fcpxml>
        """
        let timeline = try InterchangeFormat.read(Data(xml.utf8))
        #expect(timeline.name == "Vertical Edit" && timeline.rate == .fps25)
        #expect(timeline.width == 1080 && timeline.height == 1920, "vertical")
        let interview = try #require(timeline.videoTracks[0].first)
        #expect(interview.start == 0 && interview.duration == 200, "tcStart 01:00:00:00 is frame 0")
        #expect(abs(interview.sourceStart.seconds - 2) < 0.001, "source in, from the asset's own start")
        #expect(timeline.videoTracks[1].first?.start == 50 && timeline.videoTracks[1].first?.duration == 50,
                "connected 2 s into the interview's local time")
        #expect(abs((timeline.audioTracks[0].first?.gainDB ?? 0) + 3) < 0.01, "its sound comes along")
        #expect(timeline.markers.map(\.frame) == [25])
    }

    @Test func resolveOTIOWithAvailableRangeStart() throws {
        let json = """
        {"OTIO_SCHEMA":"Timeline.1","name":"Resolve TL",
         "global_start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":86400.0},
         "metadata":{"Resolve_OTIO":{"Resolution":{"width":2560,"height":1440}}},
         "tracks":{"OTIO_SCHEMA":"Stack.1","children":[
          {"OTIO_SCHEMA":"Track.1","kind":"Video","children":[
            {"OTIO_SCHEMA":"Gap.1","source_range":{"OTIO_SCHEMA":"TimeRange.1",
              "start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":0.0},
              "duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":24.0}}},
            {"OTIO_SCHEMA":"Clip.1","name":"shot",
             "source_range":{"OTIO_SCHEMA":"TimeRange.1",
               "start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":86448.0},
               "duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":48.0}},
             "media_reference":{"OTIO_SCHEMA":"ExternalReference.1","target_url":"file:///Users/me/shot.mov",
               "available_range":{"OTIO_SCHEMA":"TimeRange.1",
                 "start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":86400.0},
                 "duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":240.0}}}}]}],
          "markers":[{"OTIO_SCHEMA":"Marker.2","name":"Note","color":"RED",
            "marked_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":30.0},
              "duration":{"OTIO_SCHEMA":"RationalTime.1","rate":24.0,"value":0.0}}}]}}
        """
        let timeline = try InterchangeFormat.read(Data(json.utf8))
        #expect(timeline.rate == .fps24 && timeline.width == 2560)
        let shot = try #require(timeline.videoTracks.first?.first)
        #expect(shot.start == 24 && shot.duration == 48, "after the gap")
        #expect(abs(shot.sourceStart.seconds - 2) < 0.001, "48 frames into a file whose timecode starts at 01:00:00:00")
        #expect(timeline.markers.first?.frame == 30 && timeline.markers.first?.color == .red)
    }

    @Test func sequencesConvertBothWays() throws {
        var project = Project()
        let info = MediaInfo(container: .quickTime, duration: RationalTime(value: 30, timescale: 1),
                             video: VideoStreamInfo(codec: .h264, width: 1920, height: 1080, frameRate: rate,
                                                    nominalFPS: 29.97, bitDepth: 8, color: .rec709),
                             audio: [AudioStreamInfo(codec: .aac, sampleRate: 48_000, channelCount: 2)])
        let item = MediaItem(name: "A Cam.mov", filePath: a.path, info: info)
        project.addMedia([item])
        var report = InterchangeReport()
        let sequence = EditSequence(sample(), settings: SequenceSettings(width: 1920, height: 1080, frameRate: rate,
                                                                         colorSpace: .rec709),
                                    mediaIDs: [a.path: item.id], report: &report)
        #expect(sequence.videoTracks[0].clips.map { $0.start } == [0], "B has no media item, so it's left out")
        #expect(report.notes.contains { $0.contains("left out") })
        #expect(sequence.audioTracks[0].clips.first?.linkID != nil, "A's picture and sound are linked")
        #expect(sequence.audioTracks[0].clips.first?.linkID == sequence.videoTracks[0].clips.first?.linkID)
        #expect(sequence.markers.map { $0.name } == ["Beat"])

        var back = InterchangeReport()
        let exported = InterchangeTimeline(sequence, project: project, report: &back)
        #expect(exported.videoTracks[0].first?.media?.path == a.path)
        #expect(exported.markers.map { $0.frame } == [45])
    }
}
