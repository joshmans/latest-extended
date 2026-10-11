//
//  PackagesWindowController.swift
//  Latest
//

import Cocoa

/// A window listing outdated Homebrew and MacPorts packages, and updating the ones that need no compiling.
final class PackagesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
	
	static let shared = PackagesWindowController()
	
	/// Everything found by the last check.
	private var allPackages = [PackageUpdate]()
	
	/// What the table shows: `allPackages` after filtering and sorting.
	private var packages = [PackageUpdate]()
	
	private enum Filter: Int, CaseIterable {
		case all, ready, wouldCompile, hasEquivalent
		
		var title: String {
			switch self {
			case .all: return "All"
			case .ready: return "Ready"
			case .wouldCompile: return "Would compile"
			case .hasEquivalent: return "MacPorts equivalent"
			}
		}
		
		func includes(_ package: PackageUpdate) -> Bool {
			switch self {
			case .all: return true
			case .ready: return package.state.isPrebuilt
			case .wouldCompile: return !package.state.isPrebuilt
			case .hasEquivalent: return package.alternative != nil
			}
		}
	}
	
	private let filterControl = NSSegmentedControl(labels: Filter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
	private let table = NSTableView()
	private let log = NSTextView()
	private let statusLabel = NSTextField(labelWithString: "")
	private let spinner = NSProgressIndicator()
	private lazy var refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
	private lazy var indexButton = NSButton(title: "Update Package Indexes…", target: self, action: #selector(updateIndexes))
	private lazy var updateButton = NSButton(title: "Update Selected", target: self, action: #selector(updateSelected))
	private lazy var updateAllButton = NSButton(title: "Update All Ready…", target: self, action: #selector(updateAllReady))
	private lazy var privilegesButton = NSButton(title: "", target: self, action: #selector(configurePrivileges))
	private lazy var switchButton = NSButton(title: "Switch to MacPorts…", target: self, action: #selector(switchToMacPorts))
	private var isBusy = false { didSet { refreshControls() } }
	
	private enum Column: String, CaseIterable {
		case manager = "Manager", name = "Package", installed = "Installed", available = "Available", status = "Status", macPorts = "MacPorts equivalent"
		var width: CGFloat {
			switch self {
			case .manager: return 80
			case .name: return 170
			case .installed, .available: return 110
			case .status: return 130
			case .macPorts: return 300
			}
		}
	}
	
	private init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = "Package Updates"
		window.center()
		window.isReleasedWhenClosed = false
		window.setFrameAutosaveName("PackageUpdatesWindow")
		window.minSize = NSSize(width: 820, height: 480)
		super.init(window: window)
		buildInterface(in: window)
	}
	
	required init?(coder: NSCoder) { fatalError("Not supported") }
	
	
	// MARK: - Interface
	
	private func buildInterface(in window: NSWindow) {
		Column.allCases.forEach { column in
			let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
			tableColumn.title = column.rawValue
			tableColumn.width = column.width
			tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
			table.addTableColumn(tableColumn)
		}
		table.allowsMultipleSelection = true
		table.autosaveName = "PackageUpdatesTable"
		table.autosaveTableColumns = true
		table.usesAlternatingRowBackgroundColors = true
		table.dataSource = self
		table.delegate = self
		
		let tableScroll = NSScrollView()
		tableScroll.documentView = table
		tableScroll.hasVerticalScroller = true
		
		log.isEditable = false
		log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		let logScroll = NSScrollView()
		logScroll.documentView = log
		logScroll.hasVerticalScroller = true
		
		spinner.style = .spinning
		spinner.controlSize = .small
		spinner.isDisplayedWhenStopped = false
		statusLabel.lineBreakMode = .byTruncatingTail
		
		filterControl.selectedSegment = 0
		filterControl.target = self
		filterControl.action = #selector(filterChanged)
		let filterRow = NSStackView(views: [filterControl, NSView(), privilegesButton])
		filterRow.orientation = .horizontal
		let buttons = NSStackView(views: [spinner, statusLabel, NSView(), indexButton, refreshButton, switchButton, updateAllButton, updateButton])
		buttons.orientation = .horizontal
		
		let stack = NSStackView(views: [buttons, filterRow, tableScroll, logScroll])
		stack.orientation = .vertical
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
		stack.translatesAutoresizingMaskIntoConstraints = false
		window.contentView = NSView()
		window.contentView?.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
			stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
			stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
			logScroll.heightAnchor.constraint(equalToConstant: 96),
			buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
			filterRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
			tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
			logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24)
		])
		refreshControls()
	}
	
	/// Title and tooltip of the button controlling password-free MacPorts changes.
	private func refreshPrivilegesButton() {
		switch PrivilegedHelper.status {
		case .unavailable(let reason):
			privilegesButton.title = "Password prompt: always"
			privilegesButton.toolTip = "Password-free MacPorts changes are unavailable. \(reason)"
			privilegesButton.isEnabled = false
		case .notRegistered:
			privilegesButton.title = "Enable password-free…"
			privilegesButton.toolTip = "Install a helper so MacPorts changes do not ask for your password each time."
			privilegesButton.isEnabled = true
		case .requiresApproval:
			privilegesButton.title = "Approve helper in Settings…"
			privilegesButton.toolTip = "Allow Latest in System Settings > General > Login Items & Extensions."
			privilegesButton.isEnabled = true
		case .enabled:
			privilegesButton.title = PrivilegedHelper.isOptedIn ? "Password-free: on" : "Enable password-free…"
			privilegesButton.toolTip = "MacPorts changes run through the helper without a password prompt. Click to turn off."
			privilegesButton.isEnabled = true
		}
	}
	
	@objc private func configurePrivileges() {
		switch PrivilegedHelper.status {
		case .unavailable:
			return
			
		case .requiresApproval:
			PrivilegedHelper.openSystemSettings()
			
		case .enabled where PrivilegedHelper.isOptedIn:
			let alert = NSAlert()
			alert.messageText = "Turn off password-free MacPorts changes?"
			alert.informativeText = "The helper is removed. MacPorts changes will ask for your administrator password again."
			alert.addButton(withTitle: "Turn Off")
			alert.addButton(withTitle: "Cancel")
			if alert.runModal() == .alertFirstButtonReturn { PrivilegedHelper.disable() }
			
		default:
			let alert = NSAlert()
			alert.messageText = "Enable password-free MacPorts changes?"
			alert.informativeText = "This installs a small helper that runs as an administrator. It can only run a fixed set of MacPorts commands (install, upgrade, uninstall and selfupdate, with validated names) and only accepts requests from this app. macOS asks you to approve it once in System Settings."
			alert.addButton(withTitle: "Enable")
			alert.addButton(withTitle: "Cancel")
			guard alert.runModal() == .alertFirstButtonReturn else { return }
			do {
				try PrivilegedHelper.enable()
				if PrivilegedHelper.status == .requiresApproval { PrivilegedHelper.openSystemSettings() }
			} catch {
				append("Could not enable the helper: \(error.localizedDescription)")
			}
		}
		refreshPrivilegesButton()
	}
	
	private func refreshControls() {
		refreshPrivilegesButton()
		refreshButton.isEnabled = !isBusy
		indexButton.isEnabled = !isBusy
		updateButton.isEnabled = !isBusy && !selectedUpdatablePackages.isEmpty
		updateAllButton.isEnabled = !isBusy && allPackages.contains { $0.state.isPrebuilt }
		filterControl.isEnabled = !isBusy
		switchButton.isEnabled = !isBusy && !selectedSwitchablePackages.isEmpty && MacPortsPackageChecker.isInstalled
		isBusy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
	}
	
	private func append(_ text: String) {
		log.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
		log.scrollToEndOfDocument(nil)
	}
	
	func show() {
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
		if packages.isEmpty && !isBusy { refresh() }
	}
	
	
	// MARK: - Actions
	
	@objc private func refresh() {
		isBusy = true
		statusLabel.stringValue = "Checking Homebrew and MacPorts…"
		DispatchQueue.global().async {
			var brew = HomebrewPackageChecker.check()
			
			// Look for prebuilt MacPorts equivalents of Homebrew formulae that would have to be compiled.
			let blocked = brew.indices.filter { !brew[$0].state.isPrebuilt }
			var alternatives = [Int: PackageUpdate.Alternative]()
			let lock = NSLock()
			DispatchQueue.concurrentPerform(iterations: blocked.count) { index in
				let position = blocked[index]
				if let alternative = MacPortsPackageChecker.equivalent(forHomebrewFormula: brew[position].name) {
					lock.lock(); alternatives[position] = alternative; lock.unlock()
				}
			}
			alternatives.forEach { brew[$0.key].alternative = $0.value }
			
			let ports = MacPortsPackageChecker.check()
			let all = ports.updates + brew
			
			DispatchQueue.main.async {
				self.allPackages = all
				self.applyFilterAndSort()
				let ready = all.filter { $0.state.isPrebuilt }.count
				var summary = "\(all.count) outdated · \(ready) ready · \(all.count - ready) would compile"
				if ports.indexIsStale { summary += " · MacPorts index is old (Update Package Indexes)" }
				self.statusLabel.stringValue = summary
				self.isBusy = false
			}
		}
	}
	
	@objc private func updateIndexes() {
		isBusy = true
		statusLabel.stringValue = "Updating package indexes…"
		DispatchQueue.global().async {
			let brew = HomebrewPackageChecker.refreshIndex()
			var output = "brew update: exit \(brew.status)\n" + brew.output.suffix(800)
			if MacPortsPackageChecker.isInstalled {
				let ports = MacPortsPackageChecker.selfUpdate()
				output += "\nport selfupdate: exit \(ports.status)\n" + ports.output.suffix(800)
			}
			DispatchQueue.main.async {
				self.append(output)
				self.isBusy = false
				self.refresh()
			}
		}
	}
	
	private var selectedUpdatablePackages: [PackageUpdate] {
		table.selectedRowIndexes.compactMap { $0 < packages.count ? packages[$0] : nil }.filter { $0.state.isPrebuilt }
	}
	
	private var selectedSwitchablePackages: [PackageUpdate] {
		table.selectedRowIndexes.compactMap { $0 < packages.count ? packages[$0] : nil }.filter { $0.manager == .homebrew && $0.alternative != nil }
	}
	
	/// Replaces selected Homebrew formulae, and everything that depends on them, with prebuilt MacPorts equivalents, keeping only the MacPorts copies.
	@objc private func switchToMacPorts() {
		let selected = selectedSwitchablePackages
		guard !selected.isEmpty else { return }
		isBusy = true
		statusLabel.stringValue = "Working out what depends on the selected formulae…"
		
		DispatchQueue.global().async {
			let reverse = HomebrewPackageChecker.reverseDependencies()
			var known = Dictionary(uniqueKeysWithValues: selected.compactMap { package in package.alternative.map { (package.name, Optional($0)) } })
			let plan = PackageSwitch.plan(selected: selected, reverseDependencies: reverse) { formula in
				if let cached = known[formula] { return cached?.name }
				let alternative = MacPortsPackageChecker.equivalent(forHomebrewFormula: formula)
				known[formula] = .some(alternative)
				return alternative?.name
			}
			
			// Prebuilt archives are published for the newest port versions. A stale local index asks for versions that no longer exist.
			var archiveVersions = [String: String]()
			for alternative in known.values.compactMap({ $0 }) { archiveVersions[alternative.name] = alternative.version }
			let planned = Set(plan.groups.flatMap { $0.ports.values })
			let outdatedIndex = MacPortsPackageChecker.portsWithOutdatedIndex(archiveVersions.filter { planned.contains($0.key) })
			
			let alternativeVersions = known.compactMapValues { $0?.version }
			let installedVersions = Dictionary(uniqueKeysWithValues: selected.map { ($0.name, $0.installedVersion) })
			
			DispatchQueue.main.async {
				let blocked = plan.blocked.map { "• \($0.package) stays in Homebrew: \($0.reason)" }
				guard !plan.groups.isEmpty else {
					blocked.forEach(self.append)
					self.statusLabel.stringValue = "Nothing can be switched. See the log for why."
					self.isBusy = false
					return
				}
				
				let alert = NSAlert()
				alert.messageText = "Switch \(plan.groups.reduce(0) { $0 + $1.formulae.count }) package(s) to MacPorts?"
				var text = "Every prebuilt MacPorts port is installed first. Homebrew formulae are only uninstalled after all ports of their group are confirmed installed, dependents first.\n"
				for group in plan.groups {
					text += "\n" + group.formulae.map { formula -> String in
						var line = "• \(formula) → port \(group.ports[formula] ?? "?")"
						if let version = alternativeVersions[formula] {
							line += " \(PackageVersions.base(version))"
							if let installed = installedVersions[formula], PackageVersions.relation(of: version, to: installed) == .older {
								line += " (older than your \(PackageVersions.base(installed)))"
							}
						}
						return line + (group.pulledIn.contains(formula) ? "  (depends on your selection)" : "")
					}.joined(separator: "\n") + "\n"
				}
				if !blocked.isEmpty { text += "\nKept in Homebrew:\n" + blocked.joined(separator: "\n") + "\n" }
				if !outdatedIndex.isEmpty {
					text += "\nYour MacPorts index is out of date for \(outdatedIndex.joined(separator: ", ")), so those prebuilt archives would not be found. The index will be refreshed first (port selfupdate), which asks for your administrator password.\n"
				}
				text += "\nMacPorts versions can be older than Homebrew's. Make sure /opt/local/bin is on your PATH before /usr/local/bin."
				alert.informativeText = text
				alert.addButton(withTitle: "Switch")
				alert.addButton(withTitle: "Cancel")
				guard alert.runModal() == .alertFirstButtonReturn else {
					self.isBusy = false
					self.statusLabel.stringValue = "Cancelled."
					return
				}
				
				blocked.forEach(self.append)
				self.statusLabel.stringValue = "Installing MacPorts equivalents…"
				DispatchQueue.global().async {
					let ports = Array(Set(plan.groups.flatMap { $0.ports.values })).sorted()
					var outputs = [String]()
					// Refreshing a stale index and installing share one administrator prompt.
					var actions = [PortAction]()
					if !outdatedIndex.isEmpty { actions.append(.selfUpdate) }
					actions.append(.install(ports: ports, variants: [], binaryOnly: true))
					let results = MacPortsPackageChecker.runBatch(actions)
					for (action, result) in zip(actions, results) {
						let title = (["port"] + (action.arguments ?? [])).joined(separator: " ")
						outputs.append("\(title): exit \(result.status)\n" + result.output.suffix(1500))
					}
					
					for group in plan.groups {
						let missing = group.ports.values.filter { !MacPortsPackageChecker.isActive($0) }
						guard missing.isEmpty else {
							outputs.append("Kept \(group.formulae.joined(separator: ", ")) in Homebrew: MacPorts did not install \(missing.sorted().joined(separator: ", ")).")
							continue
						}
						for formula in group.formulae {
							guard HomebrewPackageChecker.isInstalled(formula) else {
								outputs.append("\(formula): already removed from Homebrew.")
								continue
							}
							let removal = HomebrewPackageChecker.uninstall(formula)
							outputs.append("brew uninstall \(formula): exit \(removal.status)\n" + removal.output.suffix(600))
							if removal.status != 0 {
								outputs.append("Stopped this group at \(formula). The remaining formulae were left in place; their MacPorts copies stay installed.")
								break
							}
						}
					}
					
					DispatchQueue.main.async {
						outputs.forEach(self.append)
						self.isBusy = false
						self.refresh()
					}
				}
			}
		}
	}
	
	@objc private func updateSelected() {
		performUpdate(selectedUpdatablePackages)
	}
	
	/// Updates every package that can be updated without compiling, after confirmation.
	@objc private func updateAllReady() {
		let ready = allPackages.filter { $0.state.isPrebuilt }
		guard !ready.isEmpty else { return }
		let brew = ready.filter { $0.manager == .homebrew }.count
		let ports = ready.count - brew
		
		let alert = NSAlert()
		alert.messageText = "Update \(ready.count) package(s) from prebuilt binaries?"
		alert.informativeText = "\(brew) Homebrew formula(e) and \(ports) MacPorts port(s). Nothing is compiled: Homebrew uses prebuilt bottles only and MacPorts uses prebuilt archives only. MacPorts asks for your administrator password unless the helper is enabled.\n\n" + ready.map { "• \($0.name) \($0.installedVersion) → \($0.availableVersion)" }.prefix(30).joined(separator: "\n") + (ready.count > 30 ? "\n…" : "")
		alert.addButton(withTitle: "Update")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		performUpdate(ready)
	}
	
	private func performUpdate(_ selected: [PackageUpdate]) {
		guard !selected.isEmpty else { return }
		isBusy = true
		statusLabel.stringValue = "Updating \(selected.count) package(s)…"
		
		DispatchQueue.global().async {
			var outputs = [String]()
			let brewNames = selected.filter { $0.manager == .homebrew }.map { $0.name }
			if !brewNames.isEmpty {
				let result = HomebrewPackageChecker.upgrade(brewNames)
				outputs.append("brew upgrade \(brewNames.joined(separator: " ")): exit \(result.status)\n" + result.output.suffix(1500))
			}
			let portNames = selected.filter { $0.manager == .macPorts }.map { $0.name }
			if !portNames.isEmpty {
				let result = MacPortsPackageChecker.upgrade(portNames)
				outputs.append("port -b upgrade \(portNames.joined(separator: " ")): exit \(result.status)\n" + result.output.suffix(1500))
			}
			
			DispatchQueue.main.async {
				outputs.forEach(self.append)
				self.isBusy = false
				self.refresh()
			}
		}
	}
	
	
	// MARK: - Table
	
	func numberOfRows(in tableView: NSTableView) -> Int { packages.count }
	
	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let identifier = tableColumn?.identifier.rawValue, let column = Column(rawValue: identifier) else { return nil }
		let package = packages[row]
		
		let text: String
		var tooltip: String?
		switch column {
		case .manager: text = package.manager.rawValue
		case .name: text = package.name
		case .installed: text = package.installedVersion
		case .available: text = package.availableVersion
		case .status:
			switch package.state {
			case .prebuilt:
				text = "✓ Ready"
				tooltip = "A prebuilt binary is available, so updating does not compile anything."
			case .wouldCompile(let reason):
				text = "⚠︎ Would compile"
				tooltip = reason
			}
		case .macPorts:
			if let alternative = package.alternative {
				var note = ""
				switch alternative.relation(to: package.installedVersion) {
				case .older: note = "  · older than yours"
				case .same: note = "  · same version"
				case .newer: note = "  · newer than yours"
				}
				text = "\(alternative.name) \(alternative.version)\(note)"
				tooltip = "Prebuilt MacPorts equivalent. Installed: \(package.installedVersion), Homebrew has \(package.availableVersion)."
			} else {
				text = package.manager == .homebrew && !package.state.isPrebuilt ? "none found" : ""
			}
		}
		
		let label = NSTextField(labelWithString: text)
		label.lineBreakMode = .byTruncatingTail
		label.toolTip = tooltip ?? text
		label.textColor = package.state.isPrebuilt || column == .macPorts && package.alternative != nil ? .labelColor : .secondaryLabelColor
		return label
	}
	
	
	// MARK: - Filtering and Sorting
	
	@objc private func filterChanged() {
		applyFilterAndSort()
	}
	
	func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
		applyFilterAndSort()
	}
	
	/// Rebuilds `packages` from `allPackages` for the chosen filter and sort order, keeping the selection where possible.
	private func applyFilterAndSort() {
		let selectedNames = Set(table.selectedRowIndexes.compactMap { $0 < packages.count ? "\(packages[$0].manager.rawValue)/\(packages[$0].name)" : nil })
		let filter = Filter(rawValue: filterControl.selectedSegment) ?? .all
		
		for item in Filter.allCases {
			let count = allPackages.filter(item.includes).count
			filterControl.setLabel("\(item.title) (\(count))", forSegment: item.rawValue)
		}
		
		var result = allPackages.filter(filter.includes)
		if let descriptor = table.sortDescriptors.first, let key = descriptor.key, let column = Column(rawValue: key) {
			func value(_ package: PackageUpdate) -> String {
				switch column {
				case .manager: return package.manager.rawValue
				case .name: return package.name
				case .installed: return package.installedVersion
				case .available: return package.availableVersion
				case .status: return package.state.isPrebuilt ? "0" : "1"
				case .macPorts: return package.alternative?.name ?? "~"
				}
			}
			result.sort { lhs, rhs in
				let order = value(lhs).compare(value(rhs), options: [.numeric, .caseInsensitive])
				return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
			}
		} else {
			result.sort { ($0.state.isPrebuilt ? 0 : 1, $0.manager.rawValue, $0.name) < ($1.state.isPrebuilt ? 0 : 1, $1.manager.rawValue, $1.name) }
		}
		
		packages = result
		table.reloadData()
		table.selectRowIndexes(IndexSet(packages.indices.filter { selectedNames.contains("\(packages[$0].manager.rawValue)/\(packages[$0].name)") }), byExtendingSelection: false)
		refreshControls()
	}
	
	func tableViewSelectionDidChange(_ notification: Notification) {
		refreshControls()
	}
	
}
