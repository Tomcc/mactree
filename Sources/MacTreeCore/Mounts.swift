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

public struct Folder: Sendable, Equatable {
    public let name: String
    public let path: String
}

/// The folders above `path`, from its disk down: where to go back to after
/// scanning inside it. Empty for a disk itself.
public func enclosingFolders(of path: String) -> [Folder] {
    guard let real = realpath(path, nil) else {
        return []
    }
    let resolved = String(cString: real)
    free(real)
    var info = statfs()
    guard statfs(resolved, &info) == 0 else {
        return []
    }
    let mount = mountPoint(of: info)
    guard resolved != mount else {
        return []
    }
    let base = mount == "/" ? "" : mount
    let relative: Substring
    if resolved.hasPrefix(base + "/") {
        relative = resolved.dropFirst(base.count + 1)
    } else if mount == dataVolume {
        // Firmlinked into the boot volume: /Users is the data volume's Users.
        relative = resolved.dropFirst()
    } else {
        return []
    }
    let parts = relative.split(separator: "/").dropLast()
    let disk = try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeNameKey])
    var folders = [Folder(name: disk?.volumeName ?? mount, path: mount)]
    var current = base
    for part in parts {
        current += "/" + part
        folders.append(Folder(name: String(part), path: current))
    }
    return folders
}

/// Firmlinks make /System/Volumes/Data/Users and /Users one folder; this is
/// the short form, "" for the data volume itself, for comparing paths.
public func canonicalPath(_ path: String) -> String {
    if path == dataVolume {
        return ""
    }
    return path.hasPrefix(dataVolume + "/") ? String(path.dropFirst(dataVolume.count)) : path
}
