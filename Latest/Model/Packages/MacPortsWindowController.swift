//
//  MacPortsWindowController.swift
//  Latest
//

import Cocoa

/// A window for browsing, searching, installing and uninstalling MacPorts ports.
final class MacPortsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
	
	static let shared = MacPortsWindowController()
	
	private enum Mode: Int { case search, requested, installed }
	
	private static let displayLimit = 500
	private static let categories = ["All Categories", "archivers", "audio", "databases", "devel", "editors", "games", "gnome", "graphics", "java", "lang", "math", "multimedia", "net", "python", "science", "security", "sysutils", "textproc", "www", "x11"]
	
	private var ports = [PortSummary]()
	private var installedVersions = [String: String]()
	private var requestedNames = Set<String>()
	private var searchGeneration = 0
	private var detailPrebuilt: (port: String, available: Bool)?
	private var lastQueryKey = ""
	
	private let mode = NSSegmentedControl(labels: ["Search", "Requested", "All Installed"], trackingMode: .selectOne, target: nil, action: nil)
	private let category = NSPopUpButton()
	private let searchField = NSSearchField()
	private let table = NSTableView()
	private let detail = NSTextView()
	private let log = NSTextView()
	private let statusLabel = NSTextField(labelWithString: "")
	private let spinner = NSProgressIndicator()
	private let variantsField = NSTextField()
	private lazy var installButton = NSButton(title: "Install (prebuilt)", target: self, action: #selector(install))
	private lazy var sourceButton = NSButton(title: "Build from Source…", target: self, action: #selector(buildFromSource))
	private lazy var uninstallButton = NSButton(title: "Uninstall…", target: self, action: #selector(uninstall))
	private var isBusy = false { didSet { refreshControls() } }
	
	private init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = "MacPorts"
		window.center()
		window.isReleasedWhenClosed = false
		super.init(window: window)
		buildInterface(in: window)
	}
	
	required init?(coder: NSCoder) { fatalError("Not supported") }
	
	
	// MARK: - Interface
	
	private func buildInterface(in window: NSWindow) {
		mode.selectedSegment = 0
		mode.target = self
		mode.action = #selector(modeChanged)
		category.addItems(withTitles: Self.categories)
		category.target = self
		category.action = #selector(runQuery)
		searchField.placeholderString = "Search ports by name or description"
		searchField.delegate = self
		searchField.sendsSearchStringImmediately = false
		searchField.target = self
		searchField.action = #selector(runQuery)
		spinner.style = .spinning
		spinner.controlSize = .small
		spinner.isDisplayedWhenStopped = false
		
		for (id, title, width) in [("name", "Port", 170), ("version", "Version", 90), ("installed", "Installed", 130), ("categories", "Categories", 150), ("summary", "Description", 500)] as [(String, String, CGFloat)] {
			let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
			column.title = title
			column.width = width
			table.addTableColumn(column)
		}
		table.dataSource = self
		table.delegate = self
		table.usesAlternatingRowBackgroundColors = true
		let tableScroll = NSScrollView()
		tableScroll.documentView = table
		tableScroll.hasVerticalScroller = true
		
		for view in [detail, log] {
			view.isEditable = false
			view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		}
		let detailScroll = NSScrollView(); detailScroll.documentView = detail; detailScroll.hasVerticalScroller = true
		let logScroll = NSScrollView(); logScroll.documentView = log; logScroll.hasVerticalScroller = true
		
		variantsField.placeholderString = "Variants, e.g. +x11 -quartz"
		variantsField.widthAnchor.constraint(equalToConstant: 200).isActive = true
		
		let top = NSStackView(views: [mode, category, searchField, spinner])
		let actions = NSStackView(views: [statusLabel, NSView(), variantsField, installButton, sourceButton, uninstallButton])
		for stack in [top, actions] { stack.orientation = .horizontal }
		searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
		
		let stack = NSStackView(views: [top, tableScroll, actions, detailScroll, logScroll])
		stack.orientation = .vertical
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
		stack.translatesAutoresizingMaskIntoConstraints = false
		window.contentView = NSView()
		window.contentView?.addSubview(stack)
		var constraints = [
			stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
			stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
			stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
			detailScroll.heightAnchor.constraint(equalToConstant: 150),
			logScroll.heightAnchor.constraint(equalToConstant: 100)
		]
		for view in [top, tableScroll, actions, detailScroll, logScroll] {
			constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24))
		}
		NSLayoutConstraint.activate(constraints)
		refreshControls()
	}
	
	func show() {
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
		guard MacPortsPackageChecker.isInstalled else {
			statusLabel.stringValue = "MacPorts was not found at \(MacPortsPackageChecker.portPath)."
			return
		}
		if ports.isEmpty { loadInstalledState { self.runQuery() } }
	}
	
	private var selectedPort: PortSummary? {
		let row = table.selectedRow
		return (row >= 0 && row < ports.count) ? ports[row] : nil
	}
	
	private func refreshControls() {
		let port = selectedPort
		let installed = port.flatMap { installedVersions[$0.name] } != nil
		installButton.isEnabled = !isBusy && port != nil && !installed && (detailPrebuilt?.available ?? false) && detailPrebuilt?.port == port?.name
		sourceButton.isEnabled = !isBusy && port != nil && !installed
		uninstallButton.isEnabled = !isBusy && installed
		isBusy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
	}
	
	private func append(_ text: String) {
		log.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
		log.scrollToEndOfDocument(nil)
	}
	
	
	// MARK: - Querying
	
	@objc private func modeChanged() {
		searchField.isEnabled = mode.selectedSegment == Mode.search.rawValue
		category.isEnabled = searchField.isEnabled
		runQuery()
	}
	
	func controlTextDidEndEditing(_ obj: Notification) { performQuery(force: false) }
	
	/// Reads which ports are installed, so results can show their state.
	private func loadInstalledState(then completion: @escaping () -> Void) {
		DispatchQueue.global().async {
			let port = MacPortsPackageChecker.portPath
			let installed = MacPortsParser.parseInstalled(CommandRunner.run(port, ["installed"]).output)
			let requested = Set(MacPortsParser.parseInstalled(CommandRunner.run(port, ["installed", "requested"]).output).map { $0.name })
			DispatchQueue.main.async {
				var versions = [String: String]()
				for entry in installed where entry.isActive { versions[entry.name] = entry.version }
				self.installedVersions = versions
				self.requestedNames = requested
				completion()
			}
		}
	}
	
	@objc private func runQuery() {
		performQuery(force: true)
	}
	
	private func performQuery(force: Bool) {
		guard MacPortsPackageChecker.isInstalled else { return }
		let key = "\(mode.selectedSegment)|\(category.indexOfSelectedItem)|\(searchField.stringValue.trimmingCharacters(in: .whitespaces))"
		if !force && key == lastQueryKey { return }
		lastQueryKey = key
		searchGeneration += 1
		let generation = searchGeneration
		let selectedMode = Mode(rawValue: mode.selectedSegment) ?? .search
		let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
		let chosenCategory = category.indexOfSelectedItem > 0 ? category.titleOfSelectedItem : nil
		
		if selectedMode == .search && query.isEmpty && chosenCategory == nil {
			ports = []
			table.reloadData()
			statusLabel.stringValue = "Type a search term or choose a category."
			return
		}
		
		isBusy = true
		statusLabel.stringValue = "Searching…"
		DispatchQueue.global().async {
			let port = MacPortsPackageChecker.portPath
			var results = [PortSummary]()
			switch selectedMode {
			case .search:
				if let chosenCategory {
					results = MacPortsParser.parseSearch(CommandRunner.run(port, ["search", "--line", "--category", chosenCategory]).output)
					if !query.isEmpty {
						results = results.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
					}
				} else if MacPortsParser.isValidPortName(query.replacingOccurrences(of: " ", with: "-")) || !query.contains(where: { "\"'`$;&|<>\\".contains($0) }) {
					results = MacPortsParser.parseSearch(CommandRunner.run(port, ["search", "--line", "--glob", "*\(query)*"]).output)
				}
			case .requested, .installed:
				let arguments = selectedMode == .requested ? ["installed", "requested"] : ["installed"]
				let names = Set(MacPortsParser.parseInstalled(CommandRunner.run(port, arguments).output).map { $0.name })
				results = names.sorted().map { PortSummary(name: $0, version: "", categories: [], summary: "") }
			}
			
			DispatchQueue.main.async {
				guard generation == self.searchGeneration else { return }
				let total = results.count
				var shown = Array(results.prefix(Self.displayLimit))
				for index in shown.indices {
					shown[index].installedVersion = self.installedVersions[shown[index].name]
					shown[index].isRequested = self.requestedNames.contains(shown[index].name)
				}
				self.ports = shown
				self.table.reloadData()
				self.detail.string = ""
				self.detailPrebuilt = nil
				self.statusLabel.stringValue = total > shown.count ? "Showing \(shown.count) of \(total) ports. Narrow your search." : "\(total) port(s)"
				self.isBusy = false
			}
		}
	}
	
	
	// MARK: - Detail
	
	func tableViewSelectionDidChange(_ notification: Notification) {
		detailPrebuilt = nil
		refreshControls()
		guard let port = selectedPort else { detail.string = ""; return }
		detail.string = "Loading \(port.name)…"
		
		DispatchQueue.global().async {
			let binary = MacPortsPackageChecker.portPath
			let info = MacPortsParser.parseInfo(CommandRunner.run(binary, ["info", "--index", "--fullname", "--category", "--description", "--long_description", "--homepage", "--license", "--variants", "--depends_lib", port.name]).output)
			let variants = CommandRunner.run(binary, ["variants", port.name]).output.split(separator: "\n").filter { !$0.hasPrefix("Warning") }.joined(separator: "\n")
			var archive = MacPortsParser.newestArchiveVersion(inListing: URL(string: "https://packages.macports.org/\(port.name)/").flatMap(Network.get) ?? "", port: port.name, darwin: SystemInfo.darwinMajor, arch: SystemInfo.machine)
			if !MacPortsParser.isValidPortName(port.name) { archive = nil }
			
			DispatchQueue.main.async {
				guard self.selectedPort?.name == port.name else { return }
				self.detailPrebuilt = (port.name, archive != nil)
				var text = "\(info["fullname"] ?? port.name)\n\(info["description"] ?? port.summary)\n\n"
				text += archive.map { "Prebuilt for this Mac: \(port.name) \($0)\n" } ?? "No prebuilt archive for this Mac: installing would compile from source.\n"
				if let installed = self.installedVersions[port.name] { text += "Installed: \(installed)\n" }
				text += "Categories: \(info["category"] ?? "")\nHomepage: \(info["homepage"] ?? "")\nLicense: \(info["license"] ?? "")\n"
				text += "Library dependencies: \(info["depends_lib"] ?? "none")\n\n\(variants)\n\n\(info["long_description"] ?? "")"
				self.detail.string = text
				self.refreshControls()
			}
		}
	}
	
	
	// MARK: - Actions
	
	@objc private func install() { perform(.install(buildFromSource: false)) }
	
	@objc private func buildFromSource() {
		guard let port = selectedPort else { return }
		let alert = NSAlert()
		alert.messageText = "Build \(port.name) from source?"
		alert.informativeText = "This compiles \(port.name) and any dependencies that have no prebuilt archive. On this Mac that can take a long time."
		alert.addButton(withTitle: "Build from Source")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		perform(.install(buildFromSource: true))
	}
	
	@objc private func uninstall() {
		guard let port = selectedPort else { return }
		let alert = NSAlert()
		alert.messageText = "Uninstall \(port.name)?"
		alert.informativeText = "MacPorts refuses if other installed ports depend on it. You will be asked for your administrator password."
		alert.addButton(withTitle: "Uninstall")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		perform(.uninstall)
	}
	
	private enum Action { case install(buildFromSource: Bool), uninstall }
	
	private func perform(_ action: Action) {
		guard let port = selectedPort else { return }
		let variants = variantsField.stringValue.trimmingCharacters(in: .whitespaces)
		guard MacPortsParser.isValidVariantSelection(variants) else { append("Invalid variants: \(variants)"); return }
		isBusy = true
		statusLabel.stringValue = "Working on \(port.name)…"
		
		DispatchQueue.global().async {
			let result: CommandRunner.Result
			let title: String
			switch action {
			case .install(let source):
				result = MacPortsPackageChecker.install([port.name], variants: variants, buildFromSource: source)
				title = "port install \(source ? "" : "-b ")\(port.name) \(variants)"
			case .uninstall:
				result = MacPortsPackageChecker.uninstall(port.name)
				title = "port uninstall \(port.name)"
			}
			DispatchQueue.main.async {
				self.append("\(title): exit \(result.status)\n" + result.output.suffix(1500))
				self.isBusy = false
				self.loadInstalledState { self.runQuery() }
			}
		}
	}
	
	
	// MARK: - Table
	
	func numberOfRows(in tableView: NSTableView) -> Int { ports.count }
	
	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let port = ports[row]
		let text: String
		switch tableColumn?.identifier.rawValue {
		case "name": text = port.name
		case "version": text = port.version
		case "installed": text = port.installedVersion.map { port.isRequested ? "\($0) ●" : $0 } ?? ""
		case "categories": text = port.categories.joined(separator: ", ")
		default: text = port.summary
		}
		let label = NSTextField(labelWithString: text)
		label.lineBreakMode = .byTruncatingTail
		label.toolTip = text
		return label
	}
	
}
