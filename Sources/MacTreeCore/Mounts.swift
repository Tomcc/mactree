import Darwin
import Foundation

/// Where other volumes are mounted, by parent directory. Listing such a
/// directory with `getattrlistbulk` reads each mount's root, which wakes
/// network shares and automounts; the scanner lists these by name instead.
struct ForeignMounts: Sendable {
    let byParent: [String: Set<String>]

    /// Every mount but `root`'s own volume, read without waiting on any:
    /// `MNT_NOWAIT` returns what the kernel has, even for a stalled share.
    static func current(excluding root: String) -> ForeignMounts {
        var own = statfs()
        let ownMount = statfs(root, &own) == 0 ? mountPoint(of: own) : nil
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else {
            return ForeignMounts(byParent: [:])
        }
        var infos = Array<statfs>(repeating: .init(), count: Int(count))
        let filled = infos.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, Int32(MemoryLayout<statfs>.stride) * count, MNT_NOWAIT)
        }
        var byParent: [String: Set<String>] = [:]
        for info in infos.prefix(Int(max(filled, 0))) {
            let path = mountPoint(of: info)
            guard path != "/", path != ownMount else {
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            byParent[parent, default: []].insert(name)
            // The boot volume's folders are firmlinked into its data volume:
            // /Volumes is also /System/Volumes/Data/Volumes.
            if parent != "/" && !parent.hasPrefix(dataVolume) {
                byParent[dataVolume + parent, default: []].insert(name)
            }
        }
        return ForeignMounts(byParent: byParent)
    }
}

private let dataVolume = "/System/Volumes/Data"

private func mountPoint(of info: statfs) -> String {
    withUnsafeBytes(of: info.f_mntonname) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}
