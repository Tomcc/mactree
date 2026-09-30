# mactree

A native macOS treemap for finding what fills your disk. SwiftUI port of
[tobi/disktree](https://github.com/tobi/disktree) (MIT), which is the same idea for Omarchy/Linux.

Colour is the *kind* of data (code, git, toolchains, caches…), a green outline marks space you
can get back (caches, build output, `node_modules`, Unity `Library`…), and the volume's free
space is a tile of its own. Folders keep subdividing while there is room to show them.

## Run

```sh
./scripts/bundle.sh --install     # release build → ~/Applications/MacTree.app
open ~/Applications/MacTree.app --args -path ~/Developer   # or any folder; default is ~
```

Scanning `~/Library` hits macOS privacy folders; give the app Full Disk Access to see them.
The build is ad-hoc signed, so that grant resets whenever you rebuild.

Everything is in the toolbar and the right-click menu; the Go and File menus add
`⌘↑` / `⌘↓` / `⌘⌫` / `⌘R` for keyboard users. Empty Trash goes through Finder, so macOS asks
once to let mactree control it.

## Develop

```sh
swift test                                              # scanner, layout, classification
swift run MacTree --snapshot /tmp/shot ~/Developer     # renders shot-light/-dark.png, no window
```

Needs only the Command Line Tools (Swift 6, macOS 15). The scanner uses `getattrlistbulk`
across all cores, counts allocated blocks (what `du` reports), counts hardlinks once, and
stays on one volume.
