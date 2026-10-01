import AppKit
import SwiftUI
import SWCore
import SWPlayback

/// Premiere's Audio Track Mixer: a strip per audio track (pan, mute, solo, fader, meter) and
/// the Mix strip. Faders and pan apply live during playback; double-click resets them.
struct AudioMixerPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    @StateObject private var holds = PeakHolds()

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        engine = workspace.program
    }

    var body: some View {
        if let sequence = workspace.activeSequence {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 1) {
                    ForEach(Array(sequence.audioTracks.enumerated()), id: \.element.id) { index, track in
                        trackStrip(track, name: "A\(index + 1)")
                    }
                    Divider()
                    mixStrip(sequence)
                }
                .padding(6)
            }
            .onChange(of: engine.trackMeterLevels) { _, levels in holds.update(levels, mix: engine.meterLevels) }
        } else {
            Text("Open a sequence to mix its audio tracks.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func trackStrip(_ track: Track, name: String) -> some View {
        VStack(spacing: 6) {
            Text(name).font(.system(size: 11, weight: .semibold))
            PanKnob(pan: track.pan) { pan, live in
                workspace.setTrackPan(track.id, pan, live: live)
            } onEnd: {
                workspace.endLiveEdit("Track Pan")
            }
            HStack(spacing: 4) {
                toggle("M", on: !track.isOutputEnabled, color: .green, help: "Mute") {
                    workspace.setTrackFlags(track.id, "Mute Track") { $0.isOutputEnabled.toggle() }
                }
                toggle("S", on: track.isSolo, color: .yellow, help: "Solo") {
                    workspace.setTrackFlags(track.id, "Solo Track") { $0.isSolo.toggle() }
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                Fader(dB: track.volumeDB) { dB, live in
                    workspace.setTrackVolume(track.id, dB: dB, live: live)
                } onEnd: {
                    workspace.endLiveEdit("Track Volume")
                }
                StereoMeter(levels: engine.trackMeterLevels[track.id] ?? [], holds: holds.tracks[track.id] ?? [])
            }
            Text(Mixer.label(dB: track.volumeDB)).font(Theme.smallTimecodeFont).foregroundStyle(Theme.timecode)
        }
        .frame(width: 76)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)))
    }

    private func mixStrip(_ sequence: EditSequence) -> some View {
        VStack(spacing: 6) {
            Text("Mix").font(.system(size: 11, weight: .semibold))
            Spacer().frame(height: 62)
            HStack(alignment: .bottom, spacing: 4) {
                Fader(dB: sequence.mixVolumeDB) { dB, live in
                    workspace.setMixVolume(dB: dB, live: live)
                } onEnd: {
                    workspace.endLiveEdit("Mix Volume")
                }
                StereoMeter(levels: engine.meterLevels, holds: holds.mix)
            }
            Text(Mixer.label(dB: sequence.mixVolumeDB)).font(Theme.smallTimecodeFont).foregroundStyle(Theme.timecode)
        }
        .frame(width: 76)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
    }

    private func toggle(_ title: String, on: Bool, color: Color, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? color.opacity(0.8) : Color.white.opacity(0.1)))
                .foregroundStyle(on ? Color.black : Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Peak-hold markers that fall back after 1.5 s.
@MainActor
final class PeakHolds: ObservableObject {
    @Published private(set) var tracks: [UUID: [Float]] = [:]
    @Published private(set) var mix: [Float] = []
    private var heldAt: [String: Date] = [:]

    func update(_ levels: [UUID: [Float]], mix newMix: [Float]) {
        let now = Date()
        for (id, values) in levels { tracks[id] = hold(tracks[id] ?? [], values, key: id.uuidString, now: now) }
        mix = hold(mix, newMix, key: "mix", now: now)
    }

    private func hold(_ held: [Float], _ values: [Float], key: String, now: Date) -> [Float] {
        values.indices.map { channel in
            let channelKey = "\(key)-\(channel)"
            let previous = channel < held.count ? held[channel] : 0
            if values[channel] >= previous || now.timeIntervalSince(heldAt[channelKey] ?? .distantPast) > 1.5 {
                heldAt[channelKey] = now
                return values[channel]
            }
            return previous
        }
    }
}

/// A vertical fader on a linear dB scale from -60 to +6 (the bottom is -∞).
private struct Fader: View {
    let dB: Double
    let onChange: (Double, Bool) -> Void
    let onEnd: () -> Void
    @State private var dragStart: Double?

    private static let height: CGFloat = 150
    private static func position(_ dB: Double) -> CGFloat {
        dB <= -60 ? 0 : CGFloat((min(dB, Mixer.maximumDB) + 60) / 66)
    }

    private static func dB(_ position: CGFloat) -> Double {
        position <= 0.002 ? Mixer.silentDB : Double(position) * 66 - 60
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color(white: 0.08)).frame(width: 4)
            // 0 dB tick.
            Rectangle().fill(Theme.textSecondary).frame(width: 14, height: 1)
                .offset(y: -Self.position(0) * Self.height)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 0.75))
                .frame(width: 22, height: 10)
                .offset(y: -Self.position(dB) * (Self.height - 10))
        }
        .frame(width: 26, height: Self.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? Double(Self.position(dB))
                dragStart = start
                // Fine control with ⌥.
                let scale = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1
                let moved = CGFloat(start) - drag.translation.height / Self.height * scale
                onChange(Self.dB(min(max(moved, 0), 1)), true)
            }
            .onEnded { _ in
                dragStart = nil
                onEnd()
            })
        .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0, false) })
        .help("Drag to set the level (⌥ for fine control); double-click for 0 dB")
    }
}

/// A pan knob: drag up/down; double-click centres it.
private struct PanKnob: View {
    let pan: Double
    let onChange: (Double, Bool) -> Void
    let onEnd: () -> Void
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(Color(white: 0.16)).frame(width: 32, height: 32)
                Circle().stroke(Theme.textSecondary, lineWidth: 1).frame(width: 32, height: 32)
                Rectangle().fill(Theme.accent).frame(width: 2, height: 12)
                    .offset(y: -8)
                    .rotationEffect(.degrees(pan / 100 * 135))
            }
            Text(pan == 0 ? "C" : pan < 0 ? "L\(Int(-pan.rounded()))" : "R\(Int(pan.rounded()))")
                .font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? pan
                dragStart = start
                onChange(min(max(start - Double(drag.translation.height), -100), 100).rounded(), true)
            }
            .onEnded { _ in
                dragStart = nil
                onEnd()
            })
        .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0, false) })
        .help("Drag up or down to pan; double-click to centre")
    }
}

/// Two peak meters (left, right) on a -60…0 dB scale with peak-hold lines.
private struct StereoMeter: View {
    let levels: [Float]
    let holds: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { channel in
                GeometryReader { geometry in
                    let level = channel < levels.count ? levels[channel] : (levels.first ?? 0)
                    let hold = channel < holds.count ? holds[channel] : (holds.first ?? 0)
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color(white: 0.08))
                        Rectangle()
                            .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                            .frame(height: geometry.size.height * AudioMetersPanel.fraction(forLevel: level))
                        Rectangle().fill(hold >= 1 ? Color.red : Color.white)
                            .frame(height: 1)
                            .offset(y: -geometry.size.height * AudioMetersPanel.fraction(forLevel: hold))
                            .opacity(hold > 0 ? 1 : 0)
                    }
                }
                .frame(width: 6)
            }
        }
        .frame(height: 150)
    }
}
