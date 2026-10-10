//
//  HomebrewUpdateOperation.swift
//  Latest
//
//  Copyright © 2026. All rights reserved.
//

import Foundation

/// The operation updating apps through Homebrew casks.
///
/// Casks ship prebuilt app bundles, so this never compiles anything from source.
class HomebrewUpdateOperation: UpdateOperation, @unchecked Sendable {
	
	/// The Homebrew cask token of the app.
	private let caskToken: String
	
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
		
		guard let brew = Self.brewURL else {
			finish(with: LatestError.custom(title: "Homebrew is not installed", description: "Install Homebrew from brew.sh to update this app."))
			return
		}
		
		// Apps that were not installed through brew are installed over the existing bundle.
		let isManaged = run(brew, ["list", "--cask", caskToken]).status == 0
		let arguments = isManaged
			? ["upgrade", "--cask", "--greedy", caskToken]
			: ["install", "--cask", "--force", caskToken]
		
		progressState = .installing
		let result = run(brew, arguments)
		
		if isCancelled {
			finish()
		} else if result.status != 0 {
			finish(with: LatestError.custom(title: "Homebrew could not update this app", description: String(result.output.suffix(600))))
		} else {
			finish()
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
		process.environment = environment
		
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = pipe
		self.process = process
		
		do {
			try process.run()
		} catch {
			return (-1, error.localizedDescription)
		}
		
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return (process.terminationStatus, String(decoding: data, as: UTF8.self))
	}
	
}
