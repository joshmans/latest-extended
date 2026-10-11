//
//  HomebrewUpdateOperation.swift
//  Latest
//
//  Copyright © 2026. All rights reserved.
//

import Foundation

/// Appends diagnostics about update operations to `~/Library/Logs/Latest/updates.log`.
enum UpdateLog {
	
	private static let queue = DispatchQueue(label: "UpdateLog")
	
	static let url: URL = {
		let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Latest", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory.appendingPathComponent("updates.log")
	}()
	
	/// Posted on the main thread for every line written. The line is in `userInfo["line"]`.
	static let didAppend = Notification.Name("UpdateLogDidAppend")
	
	static func write(_ message: String) {
		let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
		DispatchQueue.main.async {
			NotificationCenter.default.post(name: didAppend, object: nil, userInfo: ["line": line])
		}
		queue.sync {
			guard let data = line.data(using: .utf8) else { return }
			if let handle = try? FileHandle(forWritingTo: url) {
				handle.seekToEndOfFile()
				handle.write(data)
				try? handle.close()
			} else {
				try? data.write(to: url)
			}
		}
	}
	
}

/// Lets brew's `sudo` ask for the administrator password with a macOS dialog.
///
/// Brew runs without a terminal, so installers that need `sudo` would otherwise fail with "a terminal is required". Brew adds `sudo -A` when `SUDO_ASKPASS` is set, which calls this script. The password goes from the dialog straight to sudo; it is never stored or logged.
enum AskpassHelper {
	
	private static var directory: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Latest", isDirectory: true)
	}
	
	/// Holds the text for the dialog. `sudo` hides the environment from the script, so the reason travels through this file. Updates run one at a time, so there is only ever one current reason.
	private static var reasonURL: URL { directory.appendingPathComponent("askpass-reason.txt") }
	
	private static var scriptContents: String {
		let reasonPath = reasonURL.path.replacingOccurrences(of: "'", with: "'\\''")
		return """
		#!/bin/bash
		# Written by Latest. Shows a password dialog for sudo -A.
		REASON=$(/bin/cat '\(reasonPath)' 2>/dev/null)
		exec /usr/bin/osascript - "${REASON:-Homebrew needs your administrator password.}" <<'APPLESCRIPT'
		on run argv
			try
				set answer to display dialog (item 1 of argv) default answer "" with hidden answer with title "Latest" with icon caution buttons {"Cancel", "OK"} default button "OK" giving up after 300
				if gave up of answer then error number -128
				return text returned of answer
			on error
				error number -128
			end try
		end run
		APPLESCRIPT
		
		"""
	}
	
	/// The script's location, written on first use.
	private static var scriptURL: URL? {
		let url = directory.appendingPathComponent("askpass.sh")
		let contents = scriptContents
		
		if (try? String(contentsOf: url, encoding: .utf8)) != contents {
			do {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				try contents.write(to: url, atomically: true, encoding: .utf8)
			} catch {
				return nil
			}
		}
		try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
		return url
	}
	
	/// Environment that makes `sudo` use the dialog. Empty if the script could not be written. `reason` is shown in the dialog.
	static func environment(reason: String) -> [String: String] {
		guard let url = scriptURL else { return [:] }
		try? reason.write(to: reasonURL, atomically: true, encoding: .utf8)
		return ["SUDO_ASKPASS": url.path]
	}
	
}

/// The operation updating apps through Homebrew casks.
///
/// Casks ship prebuilt app bundles, so this never compiles anything from source.
class HomebrewUpdateOperation: UpdateOperation, @unchecked Sendable {
	
	/// The Homebrew cask token of the app.
	private let caskToken: String
	
	/// Homebrew takes locks and shares downloads between casks, so only one brew process runs at a time.
	private static let brewLock = NSLock()
	
	/// Incremented for every finished update so that a burst of updates triggers only one rescan.
	private static var rescanGeneration = 0
	
	/// The running brew process, kept for cancellation.
	private var process: Process?
	
	init(bundleIdentifier: String, appIdentifier: App.Bundle.Identifier, caskToken: String) {
		self.caskToken = caskToken
		super.init(bundleIdentifier: bundleIdentifier, appIdentifier: appIdentifier)
	}
	
	/// The location of the brew executable, if Homebrew is installed.
	static var brewURL: URL? {
		["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
			.first { FileManager.default.isExecutableFile(atPath: $0) }
			.map { URL(fileURLWithPath: $0) }
	}
	
	
	// MARK: - Operation Overrides
	
	override func execute() {
		super.execute()
		
		UpdateLog.write("[\(caskToken)] starting Homebrew update")
		
		guard let brew = Self.brewURL else {
			UpdateLog.write("[\(caskToken)] brew not found")
			finish(with: LatestError.custom(title: "Homebrew is not installed", description: "Install Homebrew from brew.sh to update this app."))
			return
		}
		
		// A cask can depend on formulae. Never let those be compiled from source.
		let blockers = HomebrewPackageChecker.compileBlockers(forCask: caskToken)
		if !blockers.isEmpty {
			UpdateLog.write("[\(caskToken)] refused: would compile \(blockers.joined(separator: ", "))")
			finish(with: LatestError.custom(title: "Update skipped: Homebrew would compile from source", description: "\(caskToken) needs \(blockers.joined(separator: ", ")), which has no prebuilt bottle for this Mac."))
			return
		}
		
		// Apps that were not installed through brew are installed over the existing bundle.
		let isManaged = run(brew, ["list", "--cask", caskToken]).status == 0
		let arguments = isManaged
			? ["upgrade", "--cask", "--greedy", caskToken]
			: ["install", "--cask", "--force", caskToken]
		
		progressState = .installing
		Self.brewLock.lock()
		UpdateLog.write("[\(caskToken)] brew \(arguments.joined(separator: " "))")
		let result = run(brew, arguments)
		Self.brewLock.unlock()
		UpdateLog.write("[\(caskToken)] exit \(result.status)")
		
		if isCancelled {
			finish()
		} else if result.status != 0 {
			finish(with: LatestError.custom(title: "Homebrew could not update this app", description: Self.failureSummary(result.output)))
		} else {
			finish()
			Self.scheduleRescan()
		}
	}
	
	/// Brew replaces the app bundle behind Latest's back, so the list keeps showing the old version until the apps are checked again.
	private static func scheduleRescan() {
		DispatchQueue.main.async {
			rescanGeneration += 1
			let generation = rescanGeneration
			DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
				guard generation == rescanGeneration else { return }
				UpdateLog.write("rescanning apps after Homebrew updates")
				UpdateCheckCoordinator.shared.rescanApps()
			}
		}
	}
	
	override func cancel() {
		process?.terminate()
		super.cancel()
	}
	
	
	// MARK: - Process Handling
	
	/// Runs brew synchronously and returns its exit status and combined output.
	private func run(_ brew: URL, _ arguments: [String]) -> (status: Int32, output: String) {
		let process = Process()
		process.executableURL = brew
		process.arguments = arguments
		
		var environment = ProcessInfo.processInfo.environment
		environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
		environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
		environment["NONINTERACTIVE"] = "1"
		environment.merge(AskpassHelper.environment(reason: "Updating \(caskToken) needs your administrator password.\n\nLatest passes it straight to the installer and does not store it.")) { $1 }
		process.environment = environment
		
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		self.process = process
		
		// Stream the output into the log as it arrives, so a running update can be watched.
		let lock = NSLock()
		var collected = Data()
		var partialLine = ""
		let token = caskToken
		pipe.fileHandleForReading.readabilityHandler = { handle in
			let data = handle.availableData
			guard !data.isEmpty else { return }
			lock.lock()
			collected.append(data)
			partialLine += String(decoding: data, as: UTF8.self)
			var lines = partialLine.components(separatedBy: .newlines)
			partialLine = lines.removeLast()
			lock.unlock()
			for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
				UpdateLog.write("[\(token)] | \(line)")
			}
		}
		
		do {
			try process.run()
		} catch {
			pipe.fileHandleForReading.readabilityHandler = nil
			return (-1, error.localizedDescription)
		}
		
		process.waitUntilExit()
		// Let the handler drain what is left, then stop it.
		Thread.sleep(forTimeInterval: 0.2)
		pipe.fileHandleForReading.readabilityHandler = nil
		let rest = pipe.fileHandleForReading.readDataToEndOfFile()
		lock.lock()
		collected.append(rest)
		lock.unlock()
		let output = String(decoding: collected, as: UTF8.self)
		return (process.terminationStatus, output)
	}
	
	/// The lines of brew output that explain a failure, without the Intel support banner brew prints around them.
	private static func failureSummary(_ output: String) -> String {
		let lines = output.components(separatedBy: .newlines)
		let relevant = lines.filter { $0.hasPrefix("Error:") || $0.hasPrefix("sudo:") }
		let summary = (relevant.isEmpty ? Array(lines.suffix(8)) : relevant).joined(separator: "\n")
		return String(summary.suffix(600))
	}
	
}
