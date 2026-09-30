import AppKit
import Observation
import QuickLookThumbnailing

/// Finder's icons and Quick Look's thumbnails, each looked up once per path:
/// the mosaic repaints on every resize.
@MainActor @Observable
final class Icons {
    static let shared = Icons()

    /// Bumped as thumbnails arrive, so the mosaic repaints with them.
    private(set) var thumbnailsVersion = 0
    @ObservationIgnored private var finderIcons: [String: NSImage] = [:]
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    func finderIcon(_ path: String) -> NSImage {
        if let icon = finderIcons[path] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        // It comes sized 32 pt, and draws from its 32 pt image when scaled up.
        icon.size = NSSize(width: 128, height: 128)
        finderIcons[path] = icon
        return icon
    }

    /// Quick Look's preview, as in Finder's lists; the Finder icon until it
    /// arrives, and for files Quick Look has nothing better for.
    func preview(_ path: String) -> NSImage {
        if let thumbnail = thumbnails[path] {
            return thumbnail
        }
        if requested.insert(path).inserted {
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path), size: CGSize(width: 128, height: 128),
                scale: 2, representationTypes: .all)
            // Called on Quick Look's own queue, not the main actor.
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                @Sendable found, _ in
                guard let image = found?.cgImage else {
                    return
                }
                Task { @MainActor in
                    self.thumbnails[path] = NSImage(
                        cgImage: image,
                        size: CGSize(width: image.width / 2, height: image.height / 2))
                    self.thumbnailsVersion += 1
                }
            }
        }
        return finderIcon(path)
    }
}
