//
//  main.swift
//  KelvinXDR
//

import Cocoa

// Read-only introspection for verifying Space Layout Protection from a shell. Prints what
// SkyLight reports and exits; touches nothing and never prompts for permission.
if CommandLine.arguments.contains("--spaces-dump") {
    print(SpaceLayoutManager.dump())
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menu bar only, no Dock icon
app.setActivationPolicy(.accessory)

app.run()
