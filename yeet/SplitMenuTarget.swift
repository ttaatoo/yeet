//
//  SplitMenuTarget.swift
//  kero
//

import AppKit

/// Target for pane-split context-menu items, kept separate from terminal menu
/// validation so these actions remain enabled even when there is no selection.
final class SplitMenuTarget: NSObject {
    var onSplit: ((PaneDropEdge) -> Void)?
    var onNewBrowserTab: ((String?) -> Void)?
    var onNewBrowserPane: ((String?) -> Void)?
    var onNewFileTab: ((String) -> Void)?
    var onNewFilePane: ((String) -> Void)?

    func browserMenuItems(initialURL: String) -> [NSMenuItem] {
        let tabItem = item(
            String(localized: "New Browser Tab"),
            #selector(newBrowserTab(_:))
        )
        tabItem.representedObject = initialURL
        let paneItem = item(
            String(localized: "New Browser Pane"),
            #selector(newBrowserPane(_:))
        )
        paneItem.representedObject = initialURL
        return [tabItem, paneItem]
    }

    func fileMenuItems(path: String) -> [NSMenuItem] {
        let tabItem = item(
            String(localized: "New File Tab"),
            #selector(newFileTab(_:))
        )
        tabItem.representedObject = path
        let paneItem = item(
            String(localized: "New File Pane"),
            #selector(newFilePane(_:))
        )
        paneItem.representedObject = path
        return [tabItem, paneItem]
    }

    func menuItems() -> [NSMenuItem] {
        [
            item(String(localized: "Split Right"), #selector(splitRight)),
            item(String(localized: "Split Left"), #selector(splitLeft)),
            item(String(localized: "Split Up"), #selector(splitUp)),
            item(String(localized: "Split Down"), #selector(splitDown)),
        ]
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func splitRight() { onSplit?(.right) }
    @objc private func splitLeft() { onSplit?(.left) }
    @objc private func splitUp() { onSplit?(.top) }
    @objc private func splitDown() { onSplit?(.bottom) }
    @objc private func newBrowserTab(_ sender: NSMenuItem) {
        onNewBrowserTab?(sender.representedObject as? String)
    }

    @objc private func newBrowserPane(_ sender: NSMenuItem) {
        onNewBrowserPane?(sender.representedObject as? String)
    }

    @objc private func newFileTab(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onNewFileTab?(path)
    }

    @objc private func newFilePane(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onNewFilePane?(path)
    }
}
