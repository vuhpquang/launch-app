// App/main.swift
// LaunchApp — a classic Launchpad for macOS 26+.

import AppKit

#if DEBUG
setvbuf(stdout, nil, _IOLBF, 0)
#endif
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Preferences.shared.settings.showInDock ? .regular : .accessory)
app.run()
