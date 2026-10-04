//
//  MainMenu.swift
//  KelvinXDR
//
//  The main menu nobody ever sees.
//
//  An LSUIElement app has no menu bar of its own, and with no nib there is no default menu
//  either — so there was nothing for ⌘W, ⌘C, ⌘V or ⌘A to resolve against. They were
//  simply dead in the Settings window and in the layout-name prompt: a text field you could
//  not paste into. Key equivalents are looked up in `NSApp.mainMenu` whether or not it is
//  ever drawn, so installing one is the whole fix.
//
//  Built here rather than in AppDelegate so the hardware-free tests can assert on it.
//

import Cocoa

enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu(title: "KelvinXDR")

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }

        // Every target is nil: the action goes down the responder chain, which is what makes
        // Paste land in whichever field is being edited and Close in whichever window is key.
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        // Deliberately no Quit. An accessory app can stay the active app with no window left —
        // after Settings or an alert closes — while the menu bar still shows the previous
        // app's menus, and ⌘Q would then quit KelvinXDR rather than the app the user is
        // looking at. Quit lives in the status menu, where it is unmistakably ours. The empty
        // submenu stays because AppKit takes the first one to be the application menu.
        submenu("KelvinXDR", [])
        submenu("File", [
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            // Undo and redo have no Swift-visible selector to name: the field editor
            // implements them, but nothing in AppKit's headers declares them.
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        return main
    }
}
