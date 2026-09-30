import AppKit
import MacTreeCore
import SwiftUI

/// Right-click menus built from the clicked tile. SwiftUI's `.contextMenu`
/// uses the last hovered tile, and no hover arrives while a menu is open, so
/// right-clicking a second tile would reopen the first one's menu.
struct ContextMenuLayer: NSViewRepresentable {
    let model: AppModel
    let tiles: [Tile]

    func makeNSView(context: Context) -> MenuView {
        MenuView()
    }

    func updateNSView(_ view: MenuView, context: Context) {
        view.model = model
        view.tiles = tiles
    }

    final class MenuView: NSView {
        var model: AppModel?
        var tiles: [Tile] = []

        override var isFlipped: Bool { true }

        /// Only right-clicks land here; everything else goes through to the
        /// SwiftUI gestures below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else {
                return nil
            }
            let rightClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return rightClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            guard let model, let content = hit(tiles, at: point)?.content else {
                return nil
            }
            model.hovered = content
            let menu = NSMenu()
            menu.autoenablesItems = false
            switch content {
            case .node(let node):
                if !node.isDir {
                    menu.addItem(ActionItem("Open") { model.launch(node) })
                } else if model.canOpen(node) {
                    menu.addItem(ActionItem("Open") { model.open(node) })
                }
                menu.addItem(ActionItem("Show in Finder") { model.revealInFinder(node) })
                menu.addItem(ActionItem("Get Info") { model.getInfo(node) })
                menu.addItem(.separator())
                let trash = ActionItem("Move to Trash") { model.moveToTrash(node) }
                trash.isEnabled = model.canTrash(node)
                menu.addItem(trash)
            case .others(let parent, _, _):
                if parent !== model.current {
                    menu.addItem(ActionItem("Open \u{201C}\(parent.displayName)\u{201D}") {
                        model.open(parent)
                    })
                }
                menu.addItem(ActionItem("Show in Finder") { model.revealInFinder(parent) })
            }
            return menu
        }
    }
}

private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("menu items are built in code")
    }

    @objc private func runAction() {
        run()
    }
}
