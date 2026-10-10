//
//  PackagesWindowController.swift
//  Latest
//

import Cocoa

/// A window listing outdated Homebrew and MacPorts packages, and updating the ones that need no compiling.
final class PackagesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
	
	static let shared = PackagesWindowController()
	
	private var packages = [PackageUpdate]()
	private let table = NSTableView()
	private let log = NSTextView()
	private let statusLabel = NSTextField(labelWithString: "")
	private let spinner = NSProgressIndicator()
	private lazy var refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
	private lazy var indexButton = NSButton(title: "Update Package Indexes…", target: self, action: #selector(updateIndexes))
	private lazy var updateButton = NSButton(title: "Update Selected", target: self, action: #selector(updateSelected))
	private lazy var switchButton = NSButton(title: "Switch to MacPorts…", target: self, action: #selector(switchToMacPorts))
	private var isBusy = false { didSet { refreshControls() } }
	
	private enum Column: String, CaseIterable {
		case manager = "Manager", name = "Package", installed = "Installed", available = "Available", status = "Status"
		var width: CGFloat {
			switch self {
			case .manager: return 80
			case .name: return 180
			case .installed, .available: return 130
			case .status: return 420
			}
		}
	}
	
	private init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = "Package Updates"
		window.center()
		window.isReleasedWhenClosed = false
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
			table.addTableColumn(tableColumn)
		}
		table.allowsMultipleSelection = true
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
		
		let buttons = NSStackView(views: [spinner, statusLabel, NSView(), indexButton, refreshButton, switchButton, updateButton])
		buttons.orientation = .horizontal
		
		let stack = NSStackView(views: [buttons, tableScroll, logScroll])
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
			logScroll.heightAnchor.constraint(equalToConstant: 140),
			buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
			tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
			logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24)
		])
		refreshControls()
	}
	
	private func refreshControls() {
		refreshButton.isEnabled = !isBusy
		indexButton.isEnabled = !isBusy
		updateButton.isEnabled = !isBusy && !selectedUpdatablePackages.isEmpty
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
			let all = (ports.updates + brew).sorted { lhs, rhs in
				(lhs.state.isPrebuilt ? 0 : 1, lhs.manager.rawValue, lhs.name) < (rhs.state.isPrebuilt ? 0 : 1, rhs.manager.rawValue, rhs.name)
			}
			
			DispatchQueue.main.async {
				self.packages = all
				self.table.reloadData()
				let ready = all.filter { $0.state.isPrebuilt }.count
				var summary = "\(all.count) outdated · \(ready) can be updated without compiling · \(all.count - ready) would compile"
				if ports.indexIsStale { summary += " · MacPorts index is old (see Update Package Indexes)" }
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
					text += "\n" + group.formulae.map { "• \($0) → port \(group.ports[$0] ?? "?")" + (group.pulledIn.contains($0) ? "  (depends on your selection)" : "") }.joined(separator: "\n") + "\n"
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
					if !outdatedIndex.isEmpty {
						let update = MacPortsPackageChecker.selfUpdate()
						outputs.append("port selfupdate: exit \(update.status)\n" + update.output.suffix(800))
					}
					let install = MacPortsPackageChecker.install(ports)
					outputs.append("port -b install \(ports.joined(separator: " ")): exit \(install.status)\n" + install.output.suffix(1500))
					
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
		let selected = selectedUpdatablePackages
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
		switch column {
		case .manager: text = package.manager.rawValue
		case .name: text = package.name
		case .installed: text = package.installedVersion
		case .available: text = package.availableVersion
		case .status:
			switch package.state {
			case .prebuilt:
				text = "Ready: prebuilt binary available"
			case .wouldCompile(let reason):
				if let alternative = package.alternative {
					text = "Would compile (\(reason)). Prebuilt in \(alternative.manager.rawValue): \(alternative.name) \(alternative.version)"
				} else {
					text = "Would compile (\(reason))"
				}
			}
		}
		
		let label = NSTextField(labelWithString: text)
		label.lineBreakMode = .byTruncatingTail
		label.toolTip = text
		label.textColor = package.state.isPrebuilt ? .labelColor : .secondaryLabelColor
		return label
	}
	
	func tableViewSelectionDidChange(_ notification: Notification) {
		refreshControls()
	}
	
}
