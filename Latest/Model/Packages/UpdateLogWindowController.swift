//
//  UpdateLogWindowController.swift
//  Latest
//

import Cocoa

/// A window showing the update log live, including the output of running brew commands.
final class UpdateLogWindowController: NSWindowController {
	
	static let shared = UpdateLogWindowController()
	
	private let textView = NSTextView()
	private let followButton = NSButton(checkboxWithTitle: "Follow output", target: nil, action: nil)
	private var observer: NSObjectProtocol?
	
	/// How much of the existing log file is shown when the window opens.
	private static let initialBytes = 200_000
	
	private init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
		window.title = "Update Log"
		window.center()
		window.isReleasedWhenClosed = false
		window.setFrameAutosaveName("UpdateLogWindow")
		window.minSize = NSSize(width: 480, height: 240)
		super.init(window: window)
		buildInterface(in: window)
	}
	
	required init?(coder: NSCoder) { fatalError("Not supported") }
	
	private func buildInterface(in window: NSWindow) {
		textView.isEditable = false
		textView.isRichText = false
		textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		textView.textContainerInset = NSSize(width: 6, height: 6)
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.autoresizingMask = [.width]
		
		let scroll = NSScrollView()
		scroll.documentView = textView
		scroll.hasVerticalScroller = true
		scroll.translatesAutoresizingMaskIntoConstraints = false
		
		followButton.state = .on
		let clear = NSButton(title: "Clear View", target: self, action: #selector(clearView))
		let reveal = NSButton(title: "Show Log File", target: self, action: #selector(revealFile))
		let buttons = NSStackView(views: [followButton, NSView(), clear, reveal])
		buttons.translatesAutoresizingMaskIntoConstraints = false
		
		let content = NSView()
		content.addSubview(scroll)
		content.addSubview(buttons)
		window.contentView = content
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: content.topAnchor),
			scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
			buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
			buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
			buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
		])
	}
	
	func show() {
		loadExistingLog()
		if observer == nil {
			observer = NotificationCenter.default.addObserver(forName: UpdateLog.didAppend, object: nil, queue: .main) { [weak self] note in
				if let line = note.userInfo?["line"] as? String { self?.append(line) }
			}
		}
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
	}
	
	/// Shows the end of the log file. Lines that arrive while the window is open are appended by the observer.
	private func loadExistingLog() {
		guard let handle = try? FileHandle(forReadingFrom: UpdateLog.url) else {
			textView.string = ""
			return
		}
		defer { handle.closeFile() }
		let size = handle.seekToEndOfFile()
		handle.seek(toFileOffset: size > UInt64(Self.initialBytes) ? size - UInt64(Self.initialBytes) : 0)
		textView.string = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
		scrollToEnd()
	}
	
	private func append(_ line: String) {
		// Only keep the observer's work small while the window is hidden.
		guard window?.isVisible == true else { return }
		textView.textStorage?.append(NSAttributedString(string: line, attributes: [.font: textView.font as Any, .foregroundColor: NSColor.textColor]))
		if followButton.state == .on { scrollToEnd() }
	}
	
	private func scrollToEnd() {
		textView.scrollToEndOfDocument(nil)
	}
	
	@objc private func clearView() {
		textView.string = ""
	}
	
	@objc private func revealFile() {
		NSWorkspace.shared.activateFileViewerSelecting([UpdateLog.url])
	}
	
}
