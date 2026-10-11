//
//  HelperProtocol.swift
//  Latest
//
//  Compiled into both the app and the privileged helper. Foundation only.
//

import Foundation

enum HelperConstants {
	
	/// The launchd label and Mach service name of the helper.
	static let machServiceName = "com.max-langer.Latest.helper"
	
	/// The launch daemon property list embedded in the app at `Contents/Library/LaunchDaemons`.
	static let daemonPlistName = "com.max-langer.Latest.helper.plist"
	
	/// The bundle identifier of the app that is allowed to talk to the helper.
	static let appIdentifier = "com.max-langer.Latest"
	
	/// The code signing identifier of the helper executable.
	static let helperIdentifier = "com.max-langer.Latest.helper"
	
	/// Bump when the protocol changes, so the app can tell an outdated helper from a current one.
	static let protocolVersion = "1"
	
	/// The code signing requirement a peer must satisfy: signed by the given team with the given identifier.
	///
	/// Returns `nil` without a team identifier, which means ad-hoc signed builds never get privileged access.
	static func requirement(identifier: String, teamIdentifier: String?) -> String? {
		guard let team = teamIdentifier, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
		return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
	}
	
}

/// What the app can ask the helper to do.
@objc protocol LatestHelperProtocol {
	
	/// The protocol version the helper implements.
	func protocolVersion(reply: @escaping (String) -> Void)
	
	/// Runs `port` with the given arguments, if they are one of the allowed `PortAction` shapes, and returns the exit status and combined output.
	func runPort(arguments: [String], reply: @escaping (Int32, String) -> Void)
	
}
