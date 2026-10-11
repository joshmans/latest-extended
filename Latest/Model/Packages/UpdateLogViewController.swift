//
//  UpdateLogViewController.swift
//  Latest
//

import Cocoa

/// The panel at the bottom of the main window that shows the update log live, including the output of running brew commands.
final class UpdateLogViewController: NSViewController {
	
	private let textView = NSTextView()
	private let followButton = NSButton(checkboxWithTitle: "Follow output", target: nil, action: nil)
	private var observer: NSObjectProtocol?
	
	/// How much of the existing log file is shown at launch.
	private static let initialBytes = 100_000
	
	/// The view is trimmed from the top beyond this many characters.
	private static let maximumCharacters = 400_000
	
	override func loadView() {
		textView.isEditable = false
		textView.isRichText = false
		textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
		textView.textContainerInset = NSSize(width: 6, height: 6)
		textView.autoresizingMask = [.width]
		
		let scroll = NSScrollView()
		scroll.documentView = textView
		scroll.hasVerticalScroller = true
		scroll.translatesAutoresizingMaskIntoConstraints = false
		
		followButton.state = .on
		let clear = NSButton(title: "Clear View", target: self, action: #selector(clearView))
		let reveal = NSButton(title: "Show Log File", target: self, action: #selector(revealFile))
		clear.controlSize = .small
		reveal.controlSize = .small
		let buttons = NSStackView(views: [followButton, NSView(), clear, reveal])
		buttons.translatesAutoresizingMaskIntoConstraints = false
		
		let content = NSView()
		content.addSubview(scroll)
		content.addSubview(buttons)
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: content.topAnchor),
			scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
			buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
			buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
			buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
			content.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
		])
		view = content
		
		loadExistingLog()
		observer = NotificationCenter.default.addObserver(forName: UpdateLog.didAppend, object: nil, queue: .main) { [weak self] note in
			if let line = note.userInfo?["line"] as? String { self?.append(line) }
		}
	}
	
	deinit {
		if let observer { NotificationCenter.default.removeObserver(observer) }
	}
	
	/// Shows the end of the log file. Lines written later arrive through the observer.
	private func loadExistingLog() {
		guard let handle = try? FileHandle(forReadingFrom: UpdateLog.url) else { return }
		defer { handle.closeFile() }
		let size = handle.seekToEndOfFile()
		handle.seek(toFileOffset: size > UInt64(Self.initialBytes) ? size - UInt64(Self.initialBytes) : 0)
		textView.string = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
		textView.scrollToEndOfDocument(nil)
	}
	
	private func append(_ line: String) {
		guard let storage = textView.textStorage else { return }
		storage.append(NSAttributedString(string: line, attributes: [.font: textView.font as Any, .foregroundColor: NSColor.textColor]))
		if storage.length > Self.maximumCharacters {
			storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - Self.maximumCharacters / 2))
		}
		if followButton.state == .on { textView.scrollToEndOfDocument(nil) }
	}
	
	@objc private func clearView() {
		textView.string = ""
	}
	
	@objc private func revealFile() {
		NSWorkspace.shared.activateFileViewerSelecting([UpdateLog.url])
	}
	
}
