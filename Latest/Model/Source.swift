//
//  Source.swift
//  Latest
//
//  Created by Max Langer on 14.03.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import AppKit

/// Small badges identifying where an app or package comes from.
enum SourceBadge {
	
	/// Homebrew's beer mug.
	static let homebrew: NSImage = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
		let font = NSFont.systemFont(ofSize: 13)
		let text = NSAttributedString(string: "🍺", attributes: [.font: font])
		let size = text.size()
		text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
		return true
	}
	
	/// MacPorts: a deep blue rounded square with "MP", unlike the other two.
	static let macPorts: NSImage = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
		NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.55, alpha: 1).setFill()
		NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
		let text = NSAttributedString(string: "MP", attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .heavy), .foregroundColor: NSColor.white])
		let size = text.size()
		text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
		return true
	}
	
	/// The image followed by the text, for table cells.
	static func label(_ image: NSImage, _ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
		let attachment = NSTextAttachment()
		attachment.image = image
		attachment.bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
		let result = NSMutableAttributedString(attachment: attachment)
		result.append(NSAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: color]))
		return result
	}
	
}

extension App {
	
	/// The source of update information.
	enum Source: String, Hashable {
		/// No known source had information about this app. It is unsupported by the update checker.
		case none
		
		/// The Sparkle Updater is the update source.
		case sparkle
		
		/// The Mac App Store is the update source.
		case appStore
		
		/// Homebrew is the update source.
		case homebrew
		
		/// The App Store app's own icon.
		private static let appStoreIcon: NSImage? = {
			let path = "/System/Applications/App Store.app"
			guard FileManager.default.fileExists(atPath: path) else { return nil }
			return NSWorkspace.shared.icon(forFile: path)
		}()
		
		/// The icon representing the source.
		var sourceIcon: NSImage? {
			switch self {
			case .none:
				return nil
			case .sparkle:
				return NSImage(named: "sparkle")
			case .appStore:
				return Self.appStoreIcon
			case .homebrew:
				return SourceBadge.homebrew
			}
		}
		
		/// The name of the source.
		var sourceName: String? {
			switch self {
			case .none:
				return nil
			case .sparkle:
				return NSLocalizedString("WebSource", comment: "The source name for apps loaded from third-party websites.")
			case .appStore:
				return NSLocalizedString("AppStoreSource", comment: "The source name of apps loaded from the App Store.")
			case .homebrew:
				return NSLocalizedString("HomebrewSource", comment: "The source name for apps checked via the Homebrew package manager.")
				
			}
		}
	}
}

// MARK: - Support State

extension App.Source {
	/// Possible states for whether a source is supported by the app.
	enum SupportState {
		/// The source is fully supported, including in-app updates.
		case full
		
		/// There is some update information available, but it may be incomplete. In-app updates do not work.
		case limited
		
		/// The source is unknown and no update information is available.
		case none
	}
	
	/// Whether the source is supported by the app.
	var supportState: SupportState {
		switch self {
		case .none:
			return .none
		case .sparkle, .appStore, .homebrew:
			return .full
		}
	}
}


// MARK: Accessors

extension App.Source.SupportState {
	/// Returns an image using the system status indicator (colored dot) for the given status.
	var statusImage: NSImage {
		let name = switch self {
		case .full: NSImage.statusAvailableName
		case .limited: NSImage.statusPartiallyAvailableName
		case .none: NSImage.statusUnavailableName
		}
		
		return NSImage(named: name)!
	}
	
	/// Returns a label briefly describing the given status.
	var label: String {
		switch self {
		case .full: NSLocalizedString("SupportedLabel", comment: "A label used for apps which are fully supported by Latest.")
		case .limited: NSLocalizedString("LimitedSupportLabel", comment: "A label used for apps which are partially supported by Latest.")
		case .none: NSLocalizedString("UnsupportedLabel", comment: "A label used for apps which are not supported by Latest.")
		}
	}
	
	/// A more compact version of the label describing the given status.
	var compactLabel: String {
		switch self {
		case .full: NSLocalizedString("SupportedCompactLabel", comment: "A compact label used for apps which are fully supported by Latest.")
		case .limited: NSLocalizedString("LimitedSupportCompactLabel", comment: "A compact label used for apps which are partially supported by Latest.")
		case .none: NSLocalizedString("UnsupportedCompactLabel", comment: "A compact label used for apps which are not supported by Latest.")
		}
	}
}
