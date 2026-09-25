# mactree

A native macOS treemap for finding what fills your disk. SwiftUI port of
[tobi/disktree](https://github.com/tobi/disktree) (MIT), which is the same idea for Omarchy/Linux.

Colour is the *kind* of data (code, git, toolchains, caches…), a hatch marks space you can
get back (caches, build output, `node_modules`, Unity `Library`…), and amber is the selection.

## Run

```sh
./scripts/bundle.sh --install     # release build → ~/Applications/MacTree.app
open ~/Applications/MacTree.app --args -path ~/Developer   # or any folder; default is ~
```

Scanning `~/Library` hits macOS privacy folders; give the app Full Disk Access to see them.
The build is ad-hoc signed, so that grant resets whenever you rebuild.

| input | does |
| --- | --- |
| click / double-click | select / open a directory |
| `⏎` · `⌫` `esc` | open selection · go up |
| `[` `]` | fewer / more levels |
| `⌘⌫` | move selection to the Trash (asks first) |
| `⌘O` `⌘R` `⌘⇧D` | open folder · rescan · whole disk |
| right-click | reveal in Finder, trash |

## Develop

```sh
swift test                                              # scanner, layout, classification
swift run MacTree --snapshot /tmp/shot.png ~/Developer  # scan + render one frame, no window
```

Needs only the Command Line Tools (Swift 6, macOS 15). The scanner uses `getattrlistbulk`
across all cores, counts allocated blocks (what `du` reports), counts hardlinks once, and
stays on one volume.
