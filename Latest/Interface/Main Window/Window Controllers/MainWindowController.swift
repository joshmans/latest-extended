//
//  MainWindowController.swift
//  Latest
//
//  Created by Max Langer on 27.02.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import Cocoa

/**
 This class controls the main window of the app. It includes the list of apps that have an update available as well as the release notes for the specific update.
 */
class MainWindowController: NSWindowController, NSMenuItemValidation, NSMenuDelegate, UpdateCheckProgressReporting {
    
	/// Encapsulates the main window items with their according tag identifiers
	private enum MainMenuItem: Int {
		case latest = 0, file, edit, view, window, help
	}
    
	/// The split view holding the list and the release notes. The window's content wraps it to make room for the update log below.
	private lazy var mainSplitViewController: NSSplitViewController? = contentViewController as? NSSplitViewController
	
	/// The panel below the main content showing the update log.
	private var logItem: NSSplitViewItem?
	
	private static let showUpdateLogKey = "ShowUpdateLogKey"
	private static let askedAboutUpdateLogKey = "AskedAboutUpdateLogKey"
	
	/// Waits for the first update to start, to offer the log once.
	private var firstUpdateObserver: NSObjectProtocol?
	
    /// The list view holding the apps
    lazy var listViewController : UpdateTableViewController = {
		let splitViewController = self.mainSplitViewController
        guard let firstItem = splitViewController?.splitViewItems[0], let controller = firstItem.viewController as? UpdateTableViewController else {
                return UpdateTableViewController()
        }
		
		// Override sidebar collapsing behavior
		firstItem.canCollapse = false
        
        return controller
    }()
    
    /// The detail view controller holding the release notes
    lazy var releaseNotesViewController : ReleaseNotesViewController = {
        guard let splitViewController = self.mainSplitViewController,
            let secondItem = splitViewController.splitViewItems[1].viewController as? ReleaseNotesViewController else {
                return ReleaseNotesViewController()
        }
        
        return secondItem
    }()
    
    /// The progress indicator showing how many apps have been checked for updates
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    
    /// The button that triggers an reload/recheck for updates
    @IBOutlet weak var reloadButton: NSButton!
    @IBOutlet weak var reloadTouchBarButton: NSButton!
    
    /// The button that triggers all available updates to be done
    @IBOutlet weak var updateAllButton: NSButton!
        
    override func windowDidLoad() {
        super.windowDidLoad()
    
		self.window?.titlebarAppearsTransparent = true
		self.window?.title = Bundle.main.localizedInfoDictionary?[kCFBundleNameKey as String] as! String

		if #available(macOS 11.0, *) {
			self.window?.toolbarStyle = .unified
		} else {
			self.window?.titleVisibility = .hidden
		}
        
		// Set ourselves as the view menu delegate
		NSApplication.shared.mainMenu?.item(at: MainMenuItem.view.rawValue)?.submenu?.delegate = self
		
		UpdateCheckCoordinator.shared.progressDelegate = self
        
        self.window?.makeFirstResponder(self.listViewController)
        self.window?.delegate = self
        
        self.listViewController.checkForUpdates()
        self.listViewController.releaseNotesViewController = self.releaseNotesViewController

        if let splitViewController = self.mainSplitViewController {
			splitViewController.splitView.autosaveName = "MainSplitView"
			
            let detailItem = splitViewController.splitViewItems[1]
            detailItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        }
		
		installUpdateLog()
		offerUpdateLogOnFirstUpdate()
    }
	
	
	// MARK: - Update Log
	
	/// Puts the update log panel below the main content and adds its checkmark item to the View menu.
	private func installUpdateLog() {
		guard let window, let mainSplit = mainSplitViewController else { return }
		let frame = window.frame
		
		let outer = NSSplitViewController()
		outer.splitView.isVertical = false
		outer.splitView.dividerStyle = .thin
		outer.splitView.autosaveName = "MainLogSplit"
		
		let mainItem = NSSplitViewItem(viewController: mainSplit)
		let logItem = NSSplitViewItem(viewController: UpdateLogViewController())
		logItem.canCollapse = true
		logItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.showUpdateLogKey)
		logItem.minimumThickness = 90
		outer.addSplitViewItem(mainItem)
		outer.addSplitViewItem(logItem)
		self.logItem = logItem
		
		window.contentViewController = outer
		window.setFrame(frame, display: true)
		
		let item = NSMenuItem(title: "Show Update Log", action: #selector(toggleUpdateLog(_:)), keyEquivalent: "l")
		item.keyEquivalentModifierMask = [.command, .shift]
		item.target = self
		if let viewMenu = NSApplication.shared.mainMenu?.item(at: MainMenuItem.view.rawValue)?.submenu {
			viewMenu.insertItem(.separator(), at: 0)
			viewMenu.insertItem(item, at: 0)
		}
	}
	
	/// The first time an update runs, asks whether the live log should be shown. The answer is final; the View menu item changes it later.
	private func offerUpdateLogOnFirstUpdate() {
		guard !UserDefaults.standard.bool(forKey: Self.askedAboutUpdateLogKey) else { return }
		
		firstUpdateObserver = NotificationCenter.default.addObserver(forName: UpdateLog.didAppend, object: nil, queue: .main) { [weak self] _ in
			guard let self else { return }
			if let observer = self.firstUpdateObserver { NotificationCenter.default.removeObserver(observer) }
			self.firstUpdateObserver = nil
			UserDefaults.standard.set(true, forKey: Self.askedAboutUpdateLogKey)
			
			// Not inside the notification: the update has already started and keeps running.
			DispatchQueue.main.async {
				guard let window = self.window else { return }
				let alert = NSAlert()
				alert.messageText = "Watch updates in the live log?"
				alert.informativeText = "The log shows what Homebrew is doing while apps update, including errors. It appears at the bottom of this window and stays on until you turn it off."
				alert.addButton(withTitle: "Show Live Log")
				alert.addButton(withTitle: "Not Now")
				alert.beginSheetModal(for: window) { response in
					if response == .alertFirstButtonReturn {
						if self.logItem?.isCollapsed == true { self.toggleUpdateLog(nil) }
					} else {
						let notice = NSAlert()
						notice.messageText = "You can turn on the log any time"
						notice.informativeText = "Choose View ▸ Show Update Log (⇧⌘L)."
						notice.beginSheetModal(for: window)
					}
				}
			}
		}
	}
	
	/// Shows or hides the update log panel.
	@IBAction func toggleUpdateLog(_ sender: Any?) {
		guard let logItem else { return }
		let show = logItem.isCollapsed
		logItem.animator().isCollapsed = !show
		UserDefaults.standard.set(show, forKey: Self.showUpdateLogKey)
	}

    
    // MARK: - Action Methods
    
    /// Reloads the list / checks for updates
    @IBAction func reload(_ sender: Any?) {
        self.listViewController.checkForUpdates()
    }
    
    /// Update all apps that can be updated from within Latest. If apps from the Mac App Store have updates as well, open the Mac App Store on its updates page.
    @IBAction func updateAll(_ sender: Any?) {
		// Iterate all updatable apps and perform update
		UpdateCheckCoordinator.shared.appProvider.updatableApps.forEach({ app in
			if !app.isUpdating {
				app.performUpdate()
			}
		})
		
		if UpdateCheckCoordinator.shared.appProvider.hasAppStoreUpdates {
			Self.openAppStoreUpdates()
		}
    }
	
	/// Opens the Mac App Store on its updates page, or just the App Store if that page cannot be opened.
	static func openAppStoreUpdates() {
		if !NSWorkspace.shared.open(AppStoreLinks.updatesPage),
		   let appStore = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") {
			NSWorkspace.shared.openApplication(at: appStore, configuration: NSWorkspace.OpenConfiguration())
		}
	}
    	
	@IBAction func performFindPanelAction(_ sender: Any?) {
		self.window?.makeFirstResponder(self.listViewController.searchField)
	}
    
	@IBAction func visitWebsite(_ sender: NSMenuItem?) {
		NSWorkspace.shared.open(URL(string: "https://max.codes/latest")!)
    }
	
	@IBAction func donate(_ sender: NSMenuItem?) {
		NSWorkspace.shared.open(URL(string: "https://max.codes/latest/donate/")!)
	}
    
    
    // MARK: Menu Item

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else {
            return true
        }
        
        switch action {
        case #selector(updateAll(_:)):
			return hasUpdatesAvailable
        case #selector(reload(_:)):
            return self.reloadButton.isEnabled
		case #selector(performFindPanelAction(_:)):
			// Only allow the find item
			return menuItem.tag == 1
        default:
            return true
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.forEach { (menuItem) in
			// Sort By menu constructed dynamically
			if menuItem.identifier == NSUserInterfaceItemIdentifier(rawValue: "sortByMenu") {
				menuItem.submenu?.items = sortByMenuItems
			}

            guard let action = menuItem.action else { return }
            
            switch action {
			case #selector(toggleUpdateLog(_:)):
				menuItem.state = (logItem?.isCollapsed ?? true) ? .off : .on
			case #selector(toggleShowInstalledUpdates(_:)):
                menuItem.state = AppListSettings.shared.showInstalledUpdates ? .on : .off
			case #selector(toggleShowIgnoredUpdates(_:)):
                menuItem.state = AppListSettings.shared.showIgnoredUpdates ? .on : .off
            default:
                ()
            }
		}
    }
	
	private var sortByMenuItems: [NSMenuItem] {
		AppListSettings.SortOptions.allCases.map { order in
			let item = NSMenuItem(title: order.displayName, action: #selector(changeSortOrder), keyEquivalent: "")
			item.representedObject = order
			item.state = AppListSettings.shared.sortOrder == order ? .on : .off
			
			return item
		}
	}
    
    
    // MARK: - Update Checker Progress Delegate
	
	func updateCheckerDidStartScanningForApps(_ updateChecker: UpdateCheckCoordinator) {
		// Disable UI
        self.reloadButton.isEnabled = false
        self.reloadTouchBarButton.isEnabled = false
		
		// Setup indeterminate progress indicator
		self.progressIndicator.isIndeterminate = true
        self.progressIndicator.isHidden = false
		self.progressIndicator.startAnimation(updateChecker)
	}
    
    /// This implementation activates the progress indicator, sets its max value and disables the reload button
	func updateChecker(_ updateChecker: UpdateCheckCoordinator, didStartCheckingApps numberOfApps: Int) {
		// Setup progress indicator
		self.progressIndicator.isIndeterminate = false
        self.progressIndicator.doubleValue = 0
        self.progressIndicator.maxValue = Double(numberOfApps - 1)
	}
    
    /// Update the progress indicator
	func updateChecker(_ updateChecker: UpdateCheckCoordinator, didCheckApp: App) {
		self.progressIndicator.increment(by: 1)
    }
	
	func updateCheckerDidFinishCheckingForUpdates(_ updateChecker: UpdateCheckCoordinator) {
		self.reloadButton.isEnabled = true
		self.reloadTouchBarButton.isEnabled = true
		self.progressIndicator.isHidden = true
        self.updateAllButton.isEnabled = hasUpdatesAvailable
	}
    
	
	// MARK: - Actions
	
	@IBAction func changeSortOrder(_ sender: NSMenuItem?) {
		AppListSettings.shared.sortOrder = sender?.representedObject as! AppListSettings.SortOptions
	}

	@IBAction func toggleShowInstalledUpdates(_ sender: NSMenuItem?) {
		AppListSettings.shared.showInstalledUpdates.toggle()
	}
	
	@IBAction func toggleShowIgnoredUpdates(_ sender: NSMenuItem?) {
		AppListSettings.shared.showIgnoredUpdates.toggle()
	}

	
	// MARK: - Accessors
	
	/// Whether there are any updatable apps.
	private var hasUpdatesAvailable: Bool {
		!UpdateCheckCoordinator.shared.appProvider.updatableApps.isEmpty || UpdateCheckCoordinator.shared.appProvider.hasAppStoreUpdates
	}

    
    // MARK: - Private Methods
    	
    private func showReleaseNotes(_ show: Bool, animated: Bool) {
        guard let splitViewController = self.mainSplitViewController else {
            return
        }
        
        let detailItem = splitViewController.splitViewItems[1]
        
        if animated {
            detailItem.animator().isCollapsed = !show
        } else {
            detailItem.isCollapsed = !show
        }
        
        if !show {
            // Deselect current app
            self.listViewController.selectApp(at: nil)
        }
    }
	
}

extension MainWindowController: NSWindowDelegate {
	
	@available(macOS, deprecated: 11.0)
	func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
		// Always position sheets at the top of the window, ignoring toolbar insets
		return NSRect(x: rect.minX, y: window.frame.height, width: rect.width, height: rect.height)
	}
    
}
