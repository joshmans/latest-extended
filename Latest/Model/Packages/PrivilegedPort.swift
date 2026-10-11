//
//  PrivilegedPort.swift
//  Latest
//

import Foundation

/// Runs `port` actions with administrator rights.
protocol PrivilegedPortRunner {
	
	/// Runs the actions in order and returns one result per action. Stops at the first action that cannot be run at all. Must not be called on the main thread.
	func run(_ actions: [PortAction]) -> [CommandRunner.Result]
	
}

/// Asks for the administrator password with the standard macOS dialog. All actions of one call share a single prompt.
struct PromptingPortRunner: PrivilegedPortRunner {
	
	static let exitMarker = "@@LATEST-EXIT:"
	
	func run(_ actions: [PortAction]) -> [CommandRunner.Result] {
		let commands = actions.compactMap { action in
			action.arguments.map { ([MacPortsPackageChecker.portPath] + $0).map(CommandRunner.shellQuote).joined(separator: " ") }
		}
		guard commands.count == actions.count, !commands.isEmpty else {
			return [CommandRunner.Result(status: -1, output: "Invalid port action.")]
		}
		
		// One shell script, so there is one password prompt. Each step reports its exit status on its own marker line.
		let script = commands.map { "\($0) 2>&1; echo \"\(Self.exitMarker)$?\"" }.joined(separator: "; ")
		let combined = CommandRunner.runAsAdministrator("/bin/sh", ["-c", script])
		return Self.splitResults(combined.output, expected: commands.count, fallbackStatus: combined.status)
	}
	
	/// Splits the combined output of a batch into one result per step.
	static func splitResults(_ output: String, expected: Int, fallbackStatus: Int32) -> [CommandRunner.Result] {
		var results = [CommandRunner.Result]()
		var current = [Substring]()
		for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
			if let range = line.range(of: exitMarker) {
				let before = line[..<range.lowerBound]
				if !before.isEmpty { current.append(before) }
				let status = Int32(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) ?? -1
				results.append(CommandRunner.Result(status: status, output: current.joined(separator: "\n")))
				current = []
			} else {
				current.append(line)
			}
		}
		// A cancelled prompt or a crash leaves steps without a marker.
		while results.count < expected {
			results.append(CommandRunner.Result(status: results.isEmpty ? fallbackStatus : -1, output: results.isEmpty ? output : "Not run."))
		}
		return results
	}
	
}

/// Chooses how privileged `port` actions are run.
enum PortPrivileges {
	
	/// The runner to use right now.
	static var runner: PrivilegedPortRunner {
		if PrivilegedHelper.isOptedIn, PrivilegedHelper.status == .enabled {
			return HelperPortRunner()
		}
		return PromptingPortRunner()
	}
	
}
