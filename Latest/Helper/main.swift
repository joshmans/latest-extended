//
//  main.swift
//  LatestHelper
//
//  A privileged helper that runs a small allow-list of MacPorts commands for Latest.
//  It runs as root under launchd, accepts connections only from Latest signed by the same team,
//  and re-validates every request, so it can never be used to run anything but those commands.
//

import Foundation

private let portPath = "/opt/local/bin/port"

final class HelperService: NSObject, NSXPCListenerDelegate, LatestHelperProtocol {
	
	/// MacPorts holds a lock while it works, so requests run one at a time.
	private let queue = DispatchQueue(label: "com.max-langer.Latest.helper.port")
	
	// MARK: - Listener
	
	func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
		// Only the signed Latest app may connect.
		guard let requirement = HelperConstants.requirement(identifier: HelperConstants.appIdentifier, teamIdentifier: clientTeamIdentifier) else { return false }
		connection.setCodeSigningRequirement(requirement)
		connection.exportedInterface = NSXPCInterface(with: LatestHelperProtocol.self)
		connection.exportedObject = self
		connection.resume()
		return true
	}
	
	// MARK: - Protocol
	
	func protocolVersion(reply: @escaping (String) -> Void) {
		reply(HelperConstants.protocolVersion)
	}
	
	func runPort(arguments: [String], reply: @escaping (Int32, String) -> Void) {
		guard PortAction(arguments: arguments) != nil else {
			reply(-1, "Rejected: not an allowed port action.")
			return
		}
		
		queue.async {
			guard FileManager.default.isExecutableFile(atPath: portPath) else {
				reply(-1, "MacPorts was not found at \(portPath).")
				return
			}
			
			let process = Process()
			process.executableURL = URL(fileURLWithPath: portPath)
			process.arguments = arguments
			process.environment = ["PATH": "/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root", "LANG": "en_US.UTF-8"]
			process.currentDirectoryURL = URL(fileURLWithPath: "/")
			
			let pipe = Pipe()
			process.standardOutput = pipe
			process.standardError = pipe
			
			do {
				try process.run()
			} catch {
				reply(-1, error.localizedDescription)
				return
			}
			
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			reply(process.terminationStatus, String(decoding: data, as: UTF8.self))
		}
	}
	
}

// The team identifier is baked in at build time by scripts/build-release.sh.
private var clientTeamIdentifier: String? {
	let team = HelperBuildSettings.teamIdentifier
	return team.isEmpty ? nil : team
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = service
listener.resume()
RunLoop.main.run()
