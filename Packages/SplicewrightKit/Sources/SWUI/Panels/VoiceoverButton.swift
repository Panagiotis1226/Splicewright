import SwiftUI
import SWCore

/// The Timeline's microphone: records a voiceover onto the targeted audio track from the
/// playhead. While it runs: the count-in, then a red dot, the time and the input level; click
/// it (or press Space) to stop and place the take.
struct VoiceoverButton: View {
    @ObservedObject var workspace: WorkspaceController

    var body: some View {
        Group {
            if let session = workspace.voiceover {
                RecordingStatus(session: session) { workspace.stopVoiceover() }
            } else {
                Button { workspace.startVoiceover() } label: { Image(systemName: "mic") }
                    .help("Record Voiceover onto the targeted audio track from the playhead (3-second count-in; "
                          + "click again or press Space to stop)")
                    .disabled(workspace.activeSequence == nil)
            }
        }
        .alert("Voiceover", isPresented: Binding(get: { workspace.voiceoverMessage != nil },
                                                 set: { if !$0 { workspace.voiceoverMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(workspace.voiceoverMessage ?? "")
        }
    }
}

private struct RecordingStatus: View {
    @ObservedObject var session: VoiceoverSession
    let stop: () -> Void

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 5) {
                switch session.phase {
                case .countIn(let count):
                    Image(systemName: "mic.fill").foregroundStyle(.orange)
                    Text("\(count)…").monospacedDigit()
                case .recording:
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(Self.time(session.seconds)).monospacedDigit()
                    LevelBar(level: session.level)
                case .finishing:
                    ProgressView().controlSize(.mini)
                    Text("Placing…")
                }
            }
        }
        .help("Stop recording (Space)")
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// The input level, in dB from -60 to 0, green into yellow into red.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        let db = 20 * log10(max(Double(level), 1e-6))
        let fraction = min(max((db + 60) / 60, 0), 1)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.12))
            RoundedRectangle(cornerRadius: 2)
                .fill(db > -3 ? Color.red : db > -12 ? Color.yellow : Color.green)
                .frame(width: 50 * fraction)
        }
        .frame(width: 50, height: 6)
    }
}
