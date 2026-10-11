//
//  PrivilegedHelper.swift
//  Latest
//

import Foundation
import ServiceManagement
import Security

/// Manages the optional privileged helper that lets Latest run MacPorts changes without asking for the administrator password each time.
///
/// The helper is a launch daemon embedded in the app. The user approves it once in System Settings > General > Login Items & Extensions.
/// It only exists in builds signed with a developer team (see `scripts/build-release.sh`); everything else falls back to the password prompt.
enum PrivilegedHelper {
	
	enum Status: Equatable {
		/// The helper cannot be used in this build. The reason can be shown to the user.
		case unavailable(reason: String)
		
		/// The helper is bundled but not registered.
		case notRegistered
		
		/// Registered; waiting for the user to approve it in System Settings.
		case requiresApproval
		
		/// Registered and approved.
		case enabled
	}
	
	/// User defaults key recording that the user turned the helper on.
	static let optInKey = "UsePrivilegedHelperKey"
	
	static var isOptedIn: Bool {
		UserDefaults.standard.bool(forKey: optInKey)
	}
	
	
	// MARK: - Status
	
	/// The team identifier this app was signed with, if any.
	static var ownTeamIdentifier: String? {
		var code: SecCode?
		var staticCode: SecStaticCode?
		var information: CFDictionary?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
			  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
			  SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			  let dictionary = information as? [String: Any] else { return nil }
		return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
	}
	
	static var status: Status {
		guard #available(macOS 13.0, *) else {
			return .unavailable(reason: "Requires macOS 13 or later.")
		}
		let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperConstants.daemonPlistName)")
		guard FileManager.default.fileExists(atPath: plist.path) else {
			return .unavailable(reason: "This build does not include the helper. Build with scripts/build-release.sh and a signing identity.")
		}
		guard HelperConstants.requirement(identifier: HelperConstants.helperIdentifier, teamIdentifier: ownTeamIdentifier) != nil else {
			return .unavailable(reason: "This build is not signed with a developer team.")
		}
		
		switch SMAppService.daemon(plistName: HelperConstants.daemonPlistName).status {
		case .enabled: return .enabled
		case .requiresApproval: return .requiresApproval
		case .notFound: return .unavailable(reason: "The helper could not be found in the app.")
		default: return .notRegistered
		}
	}
	
	
	// MARK: - Enabling
	
	/// Registers the helper. If macOS needs the user's approval, the status becomes `requiresApproval`.
	static func enable() throws {
		guard #available(macOS 13.0, *) else { return }
		UserDefaults.standard.set(true, forKey: optInKey)
		try SMAppService.daemon(plistName: HelperConstants.daemonPlistName).register()
	}
	
	static func disable() {
		UserDefaults.standard.set(false, forKey: optInKey)
		guard #available(macOS 13.0, *) else { return }
		try? SMAppService.daemon(plistName: HelperConstants.daemonPlistName).unregister()
	}
	
	/// Opens System Settings on the Login Items page, where the helper can be approved.
	static func openSystemSettings() {
		if #available(macOS 13.0, *) { SMAppService.openSystemSettingsLoginItems() }
	}
	
	
	// MARK: - Running
	
	/// Runs the actions through the helper. Returns `nil` if the helper cannot be reached, so the caller can fall back to the password prompt.
	static func run(_ actions: [PortAction]) -> [CommandRunner.Result]? {
		guard #available(macOS 13.0, *),
			  let requirement = HelperConstants.requirement(identifier: HelperConstants.helperIdentifier, teamIdentifier: ownTeamIdentifier) else { return nil }
		
		let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
		connection.remoteObjectInterface = NSXPCInterface(with: LatestHelperProtocol.self)
		connection.setCodeSigningRequirement(requirement)
		connection.resume()
		defer { connection.invalidate() }
		
		var results = [CommandRunner.Result]()
		for action in actions {
			guard let arguments = action.arguments else { return results.isEmpty ? nil : results + [.init(status: -1, output: "Invalid port action.")] }
			
			let semaphore = DispatchSemaphore(value: 0)
			var result: CommandRunner.Result?
			let proxy = connection.remoteObjectProxyWithErrorHandler { _ in semaphore.signal() } as? LatestHelperProtocol
			proxy?.runPort(arguments: arguments) { status, output in
				result = CommandRunner.Result(status: status, output: output)
				semaphore.signal()
			}
			semaphore.wait()
			
			guard let result else { return results.isEmpty ? nil : results }
			results.append(result)
		}
		return results
	}
	
}

/// Runs actions through the helper, falling back to the password prompt if the helper is not reachable.
struct HelperPortRunner: PrivilegedPortRunner {
	
	func run(_ actions: [PortAction]) -> [CommandRunner.Result] {
		PrivilegedHelper.run(actions) ?? PromptingPortRunner().run(actions)
	}
	
}
