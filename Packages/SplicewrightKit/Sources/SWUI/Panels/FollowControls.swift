import SwiftUI
import SWCore

/// Follow, under Motion: make the clip move with a tracked mask on another clip (a name over a
/// person, a logo on a sign), with or without its scale and rotation. It keeps where it is now,
/// relative to the mask, from the playhead on.
struct FollowControls: View {
    @ObservedObject var workspace: WorkspaceController
    let clip: Clip

    private var candidates: [(clip: Clip, owner: MaskOwner, mask: Mask)] {
        workspace.activeSequence?.followableMasks(for: clip) ?? []
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 26)
            Text("Follow").frame(width: 82, alignment: .leading)
            Menu {
                Button("Nothing") { workspace.setFollow(nil, of: clip.id) }
                if !candidates.isEmpty { Divider() }
                ForEach(candidates.indices, id: \.self) { index in
                    let candidate = candidates[index]
                    Button(label(candidate.clip, candidate.owner, candidate.mask)) {
                        workspace.follow(clip.id, target: candidate.clip.id, owner: candidate.owner, mask: candidate.mask.id)
                    }
                }
                if candidates.isEmpty {
                    Text("Track a mask on a clip under this one first")
                }
            } label: {
                Text(current).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move with a tracked mask on another clip. It keeps its place relative to the mask from the playhead.")
            if let link = clip.follow {
                Toggle("Scale", isOn: Binding(get: { link.followsScale }, set: { value in
                    var updated = link
                    updated.followsScale = value
                    workspace.setFollow(updated, of: clip.id)
                }))
                Toggle("Rotation", isOn: Binding(get: { link.followsRotation }, set: { value in
                    var updated = link
                    updated.followsRotation = value
                    workspace.setFollow(updated, of: clip.id)
                }))
            }
            Spacer()
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    private var current: String {
        guard let link = clip.follow else { return "Nothing" }
        guard let target = workspace.activeSequence?.clip(link.targetClipID),
              let mask = target.masks(of: link.owner).first(where: { $0.id == link.maskID }) else { return "(missing)" }
        return label(target, link.owner, mask)
    }

    private func label(_ target: Clip, _ owner: MaskOwner, _ mask: Mask) -> String {
        switch owner {
        case .opacity: return "\(target.name) ▸ \(mask.name)"
        case .effect(let id):
            let effect = target.effects.first { $0.id == id }?.kind.displayName ?? "Effect"
            return "\(target.name) ▸ \(effect) ▸ \(mask.name)"
        }
    }
}
