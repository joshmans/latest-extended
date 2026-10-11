//
//  AppDelegate.swift
//  Latest
//
//  Created by Max Langer on 15.02.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
		installPackagesMenuItem()
    }
	
	/// Adds the entry for the package updates window to the second menu (File).
	private func installPackagesMenuItem() {
		guard let menu = NSApp.mainMenu?.items.dropFirst().first?.submenu else { return }
		let item = NSMenuItem(title: "Package Updates…", action: #selector(showPackageUpdates), keyEquivalent: "p")
		item.keyEquivalentModifierMask = [.command, .shift]
		item.target = self
		let ports = NSMenuItem(title: "MacPorts…", action: #selector(showMacPorts), keyEquivalent: "m")
		ports.keyEquivalentModifierMask = [.command, .shift]
		ports.target = self
		let log = NSMenuItem(title: "Update Log…", action: #selector(showUpdateLog), keyEquivalent: "l")
		log.keyEquivalentModifierMask = [.command, .shift]
		log.target = self
		menu.insertItem(item, at: 0)
		menu.insertItem(ports, at: 1)
		menu.insertItem(log, at: 2)
		menu.insertItem(.separator(), at: 3)
	}
	
	@objc private func showUpdateLog() {
		UpdateLogWindowController.shared.show()
	}
	
	@objc private func showMacPorts() {
		MacPortsWindowController.shared.show()
	}
	
	@objc private func showPackageUpdates() {
		PackagesWindowController.shared.show()
	}

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
	
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		// Always terminate the app if the main window is closed
		return true
	}
    
}

