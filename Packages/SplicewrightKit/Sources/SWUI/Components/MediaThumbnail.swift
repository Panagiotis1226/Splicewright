import SwiftUI
import SWCore
import SWMedia

/// A clip's poster frame, loaded asynchronously from the thumbnail cache.
struct MediaThumbnail: View {
    let item: MediaItem
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: item.info.kind == .audio ? "waveform" : "film")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .task(id: item.id) {
            guard item.info.video != nil, MediaLocator.isOnline(item) else { return }
            // A frame a little way in avoids black leaders on many clips.
            let seconds = min(1.0, item.info.duration.seconds / 4)
            image = await ThumbnailProvider.shared.thumbnail(for: item.url, at: seconds)
        }
    }
}

/// Draws audio peaks as a mirrored filled waveform across the view's width.
struct WaveformView: View {
    let peaks: WaveformPeaks
    let duration: Double
    var color: Color = Theme.waveform

    var body: some View {
        Canvas { context, size in
            guard duration > 0, size.width > 0 else { return }
            let columns = Int(size.width)
            let secondsPerColumn = duration / Double(columns)
            let midY = size.height / 2
            var path = Path()
            for column in 0..<columns {
                let start = Double(column) * secondsPerColumn
                let amplitude = CGFloat(peaks.peak(from: start, to: start + secondsPerColumn))
                let half = max(0.5, amplitude * midY)
                path.addRect(CGRect(x: CGFloat(column), y: midY - half, width: 1, height: half * 2))
            }
            context.fill(path, with: .color(color))
        }
    }
}
