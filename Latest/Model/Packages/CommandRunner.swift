//
//  CommandRunner.swift
//  Latest
//

import Foundation

/// Runs command line tools synchronously. Must not be called on the main thread.
enum CommandRunner {
	
	struct Result {
		let status: Int32
		let output: String
	}
	
	static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) -> Result {
		assert(!Thread.isMainThread, "Must not be called on main thread.")
		
		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
		
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		
		do {
			try process.run()
		} catch {
			return Result(status: -1, output: error.localizedDescription)
		}
		
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
	}
	
	/// Runs a shell command as administrator, showing the standard macOS authentication dialog.
	static func runAsAdministrator(_ executable: String, _ arguments: [String]) -> Result {
		let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
		let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
		return run("/usr/bin/osascript", ["-e", script])
	}
	
	/// Quotes the given string for safe use in a POSIX shell.
	static func shellQuote(_ string: String) -> String {
		"'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
	
}
