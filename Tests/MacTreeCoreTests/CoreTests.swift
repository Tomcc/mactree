import CoreGraphics
import Darwin
import Foundation
import Testing

@testable import MacTreeCore

/// A throwaway directory tree, removed when the test ends.
final class TempTree {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "mactree-test-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        chmod(root + "/locked", 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }

    func file(_ relative: String, bytes: Int) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    func blocks(_ relative: String) -> UInt64 {
        var info = stat()
        precondition(lstat(root + "/" + relative, &info) == 0)
        return UInt64(info.st_blocks) * 512
    }
}

func child(_ node: Node, _ names: String...) -> Node {
    names.reduce(node) { node, name in
        guard let found = node.children.first(where: { $0.name == name }) else {
            fatalError("no \(name) under \(node.path)")
        }
        return found
    }
}

@Test func scanSizesMatchStatBlocks() throws {
    let tree = try TempTree()
    try tree.file("a/big.bin", bytes: 1_000_000)
    try tree.file("a/b/small.txt", bytes: 10)
    try tree.file("top.txt", bytes: 5000)

    let root = Scanner.scan(tree.root, progress: ScanProgress())
    let inA = tree.blocks("a/big.bin") + tree.blocks("a/b/small.txt")
    #expect(root.bytes == inA + tree.blocks("top.txt"))
    #expect(root.files == 3)
    #expect(root.dirs == 2)
    #expect(child(root, "a").bytes == inA)
    #expect(root.children.first?.name == "a", "largest first")
    #expect(child(root, "a", "b", "small.txt").path == tree.root + "/a/b/small.txt")
}

@Test func hardlinksCountOnce() throws {
    let tree = try TempTree()
    try tree.file("one", bytes: 200_000)
    #expect(link(tree.root + "/one", tree.root + "/two") == 0)
    let root = Scanner.scan(tree.root, progress: ScanProgress())
    #expect(root.bytes == tree.blocks("one"))
    #expect(root.files == 2)
}

@Test func unreadableDirectoriesAreCountedNotGuessed() throws {
    let tree = try TempTree()
    try tree.file("locked/secret", bytes: 100)
    #expect(chmod(tree.root + "/locked", 0) == 0)
    let root = Scanner.scan(tree.root, progress: ScanProgress())
    #expect(root.unreadable == 1)
    #expect(child(root, "locked").unreadableHere)
}

@Test func symlinksAreNotFollowed() throws {
    let tree = try TempTree()
    try tree.file("real/data", bytes: 500_000)
    #expect(symlink(tree.root + "/real", tree.root + "/alias") == 0)
    let root = Scanner.scan(tree.root, progress: ScanProgress())
    #expect(!child(root, "alias").isDir)
    #expect(child(root, "alias").bytes < 100_000)
}

@Test func progressCountsEveryEntry() throws {
    let tree = try TempTree()
    for index in 0..<50 {
        try tree.file("d\(index % 5)/f\(index)", bytes: 1)
    }
    let progress = ScanProgress()
    _ = Scanner.scan(tree.root, progress: progress)
    #expect(progress.count == 55)
}

@Test func classificationFindsReclaimableGitAndInherits() throws {
    let tree = try TempTree()
    try tree.file(".cache/kache/store/b", bytes: 1)
    try tree.file("rusty/Cargo.toml", bytes: 1)
    try tree.file("rusty/target/debug/c", bytes: 1)
    try tree.file("jsy/target/d", bytes: 1)
    try tree.file("app/Logs/today.log", bytes: 1)
    try tree.file("world/.git/objects/e", bytes: 9000)
    try tree.file("world/.git/lfs/cache/x", bytes: 1)
    try tree.file("bare/HEAD", bytes: 1)
    try tree.file("bare/refs/r", bytes: 1)
    try tree.file("bare/objects/p", bytes: 1)
    try tree.file("Library/stuff", bytes: 1)
    let root = Scanner.scan(tree.root, progress: ScanProgress())

    #expect(child(root, ".cache", "kache", "store").kind == .reclaimable)
    #expect(child(root, ".cache", "kache", "store").reclaim == .regenerable)
    #expect(child(root, "rusty", "target").reclaim == .buildOutput)
    #expect(child(root, "jsy", "target").kind == .other)
    #expect(child(root, "app", "Logs", "today.log").reclaim == .logs, "files inherit")
    #expect(child(root, "world").kind == .other)
    #expect(child(root, "world", ".git", "objects").kind == .git)
    #expect(child(root, "world", ".git", "lfs", "cache").kind == .reclaimable,
        "reclaimable wins over git")
    #expect(child(root, "bare").kind == .git, "a bare repository by its shape")
    #expect(child(root, "Library").kind == .other, "system names only at a volume root")
}

@Test func volumeRootsAreDetected() {
    #expect(isVolumeRoot("/"))
    #expect(!isVolumeRoot(NSTemporaryDirectory()))
}

@Test func squarifyFillsTheAreaWithSaneAspects() {
    let area = CGRect(x: 0, y: 0, width: 600, height: 400)
    let rects = squarify([6, 6, 4, 3, 2, 2, 1], in: area)
    let covered = rects.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(covered - area.width * area.height) < 1)
    for rect in rects {
        #expect(area.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        #expect(max(rect.width / rect.height, rect.height / rect.width) <= 4)
    }
    #expect(squarify([], in: area).isEmpty)
    #expect(squarify([0, 0], in: area).allSatisfy { $0 == .zero })
}

@Test func layoutNestsChildrenBelowTheirHeader() {
    let root = Node(name: "/r", isDir: true)
    let big = Node(name: "big", isDir: true)
    root.adopt(big)
    big.adopt(Node(name: "inside", isDir: false, bytes: 100))
    big.adopt(Node(name: "also", isDir: false, bytes: 50))
    root.adopt(Node(name: "small", isDir: false, bytes: 10))
    root.aggregate()

    let tiles = layout(
        root, in: CGRect(x: 0, y: 0, width: 800, height: 500), options: LayoutOptions())
    #expect(tiles.map { $0.node?.name } == ["big", "inside", "also", "small"])
    let header = tiles[0].header!
    for inner in tiles[1...2] {
        #expect(inner.rect.minY >= header.maxY)
        #expect(tiles[0].rect.contains(inner.rect))
    }
    #expect(hit(tiles, at: CGPoint(x: header.midX, y: header.midY))?.node === big)
    let inChild = CGPoint(x: tiles[1].rect.midX, y: tiles[1].rect.midY)
    #expect(hit(tiles, at: inChild)?.node?.name == "inside")
}

@Test func longChildListsMergeTheirTail() {
    let root = Node(name: "/r", isDir: true)
    for index in 0..<10 {
        root.adopt(Node(name: "f\(index)", isDir: false, bytes: UInt64(10 - index)))
    }
    root.aggregate()
    var options = LayoutOptions()
    options.maxChildren = 4
    let tiles = layout(root, in: CGRect(x: 0, y: 0, width: 800, height: 500), options: options)
    let others = tiles.compactMap { tile -> UInt64? in
        if case .others(_, let bytes, _) = tile.content {
            return bytes
        }
        return nil
    }
    #expect(others == [21], "the tail's bytes: 6 + 5 + 4 + 3 + 2 + 1")
}

@Test func dustMergesIntoOneTileBesideABigChild() {
    let root = Node(name: "/r", isDir: true)
    root.adopt(Node(name: "big", isDir: false, bytes: 1_000_000))
    for index in 0..<200 {
        root.adopt(Node(name: "dust\(index)", isDir: false, bytes: 10))
    }
    root.aggregate()
    let tiles = layout(root, in: CGRect(x: 0, y: 0, width: 800, height: 500), options: LayoutOptions())
    #expect(tiles.count <= 2)
    #expect(tiles.first?.node?.name == "big")
    for tile in tiles where tile.node != nil {
        #expect(tile.rect.width >= 30 && tile.rect.height >= 30, "every file fits a label")
    }
}

@Test func formatting() {
    #expect(formatBytes(0) == "0 B")
    #expect(formatBytes(881_000_000_000) == "881 GB")
    #expect(formatBytes(9_700_000_000) == "9.7 GB")
    #expect(formatBytes(15_200_000) == "15 MB")
    #expect(formatCount(3_900_000) == "3.9M")
}

@Test func aFolderOfOnlyDustStaysWhole() {
    let root = Node(name: "/r", isDir: true)
    let objects = Node(name: "objects", isDir: true)
    for index in 0..<256 {
        let bucket = Node(name: "\(index)", isDir: true)
        bucket.adopt(Node(name: "pack", isDir: false, bytes: 10))
        objects.adopt(bucket)
    }
    root.adopt(objects)
    root.aggregate()
    let tiles = layout(root, in: CGRect(x: 0, y: 0, width: 800, height: 500), options: LayoutOptions())
    #expect(tiles.count == 1, "subdividing would only show one small items tile")
    #expect(tiles.first?.node === objects && tiles.first?.header == nil)
}

@Test func everyChildIsDrawnOrMerged() {
    var seed: UInt64 = 42
    func random() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed >> 33
    }
    let options = LayoutOptions()
    for trial in 0..<200 {
        let root = Node(name: "/r", isDir: true)
        for index in 0..<Int(random() % 80 + 2) {
            root.adopt(Node(name: "f\(index)", isDir: false, bytes: random() % 1_000_000 + 1))
        }
        root.aggregate()
        let area = CGRect(x: 0, y: 0, width: Double(random() % 1200 + 200), height: 500)
        let tiles = layout(root, in: area, options: options)
        let covered = tiles.reduce(0) { sum, tile in
            let raw = tile.rect.insetBy(dx: -options.rootPadding, dy: -options.rootPadding)
            return sum + raw.width * raw.height
        }
        // Small items thinner than the gaps vanish, but only as a gap-thin sliver.
        let hole = area.width * area.height - covered
        let sliver = 2 * options.padding * max(area.width, area.height)
        #expect(hole < sliver, "trial \(trial) left a hole")
    }
}

@Test func levelsBelowFollowTheDeepestBranch() {
    let root = Node(name: "/r", isDir: true)
    let deep = Node(name: "deep", isDir: true)
    let middle = Node(name: "middle", isDir: true)
    middle.adopt(Node(name: "a", isDir: false, bytes: 600))
    middle.adopt(Node(name: "b", isDir: false, bytes: 400))
    deep.adopt(middle)
    deep.adopt(Node(name: "leaf", isDir: false, bytes: 1000))
    root.adopt(deep)
    root.adopt(Node(name: "file", isDir: false, bytes: 1000))
    root.aggregate()
    let tiles = layout(root, in: CGRect(x: 0, y: 0, width: 1600, height: 1000), options: LayoutOptions())
    let levels = Dictionary(uniqueKeysWithValues: tiles.compactMap { tile in
        tile.node.map { ($0.name, tile.levelsBelow) }
    })
    #expect(levels == ["deep": 2, "middle": 1, "a": 0, "b": 0, "leaf": 0, "file": 0])
}
