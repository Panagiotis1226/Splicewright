import AppKit
import SwiftUI
import SWCore
import SWMedia

/// Settings ▸ Media: how proxies are made and where they're kept.
struct MediaSettingsView: View {
    @ObservedObject var preferences: MediaPreferences

    var body: some View {
        Form {
            Section("Proxies") {
                Picker("Resolution", selection: $preferences.proxyPreset.resolution) {
                    ForEach(ProxyPreset.Resolution.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Format", selection: $preferences.proxyPreset.codec) {
                    ForEach(ProxyPreset.Codec.allCases, id: \.self) { codec in
                        Text("\(codec.displayName): about \(perHour(codec)) per hour of 4K30").tag(codec)
                    }
                }
                Text(preferences.proxyPreset.codec.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Create proxies automatically when importing media larger than this",
                       isOn: $preferences.autoCreateProxies)
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text((preferences.proxyLocation ?? ProxyStore.defaultRoot).path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Button("Choose…", action: chooseLocation)
                            Button("Use Default") { preferences.proxyLocation = nil }
                                .disabled(preferences.proxyLocation == nil)
                        }
                    }
                }
                Text("For comparison, iPhone 4K30 HEVC video is about 22 GB per hour. On Apple silicon a single "
                     + "4K30 HEVC clip usually plays smoothly without proxies; they help most with 4K60, several "
                     + "layers, HDR with effects, or slower Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Proxies are lighter copies of your video for smooth playback. Turn them on with the P button on "
                     + "either monitor (or View ▸ Use Proxies). Export always uses the original media. Proxies made "
                     + "in one location aren't moved when you change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 360)
    }

    private func perHour(_ codec: ProxyPreset.Codec) -> String {
        var preset = preferences.proxyPreset
        preset.codec = codec
        let bytes = preset.bytesPerHour(sourceWidth: 3840, sourceHeight: 2160, fps: 30)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = preferences.proxyLocation ?? ProxyStore.defaultRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.proxyLocation = url
    }
}
