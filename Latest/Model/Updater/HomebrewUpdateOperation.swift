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
/// Brew runs without a terminal, so installers that need `sudo` would otherwise fail with "a terminal is required". Brew adds `sudo -A` when `SUDO_ASKPASS` is set, which calls this script.
///
/// The dialog offers "All This Session". That password is checked against `sudo`, then kept in Latest's memory only (never written to disk or logged) and handed to later askpass calls through a socket that only this user can reach. It is forgotten after 30 minutes or when Latest quits.
enum AskpassHelper {
	
	private static var directory: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Latest", isDirectory: true)
	}
	
	/// Holds the text for the dialog. `sudo` hides the environment from the script, so the reason travels through this file. Updates run one at a time, so there is only ever one current reason.
	private static var reasonURL: URL { directory.appendingPathComponent("askpass-reason.txt") }
	
	static var socketURL: URL { directory.appendingPathComponent("askpass.sock") }
	
	private static func shellQuote(_ string: String) -> String {
		"'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
	
	private static var scriptContents: String {
		return """
		#!/bin/bash
		# Written by Latest. Shows a password dialog for sudo -A.
		SOCK=\(shellQuote(socketURL.path))
		REASON=$(/bin/cat \(shellQuote(reasonURL.path)) 2>/dev/null)
		REASON=${REASON:-Homebrew needs your administrator password.}
		
		# A password the user chose to keep for this session.
		CACHED=$(printf 'GET\\n' | /usr/bin/nc -w 2 -U "$SOCK" 2>/dev/null | /usr/bin/head -n 1)
		if [ -n "$CACHED" ]; then
			printf '%s\\n' "$CACHED"
			exit 0
		fi
		
		valid() { printf '%s\\n' "$1" | /usr/bin/sudo -S -k -p '' -v >/dev/null 2>&1; }
		
		MESSAGE="$REASON"
		PASSWORD=""
		for ATTEMPT in 1 2 3; do
			OUT=$(/usr/bin/osascript - "$MESSAGE" <<'APPLESCRIPT'
		on run argv
			try
				set answer to display dialog (item 1 of argv) default answer "" with hidden answer with title "Latest" with icon caution buttons {"Cancel", "This App Only", "All This Session"} default button "All This Session" cancel button "Cancel" giving up after 300
				if gave up of answer then error number -128
				return (button returned of answer) & linefeed & (text returned of answer)
			on error
				error number -128
			end try
		end run
		APPLESCRIPT
			) || exit 1
			BUTTON=$(printf '%s\\n' "$OUT" | /usr/bin/head -n 1)
			PASSWORD=$(printf '%s\\n' "$OUT" | /usr/bin/tail -n +2 | /usr/bin/head -n 1)
			if [ -n "$PASSWORD" ] && valid "$PASSWORD"; then
				if [ "$BUTTON" = "All This Session" ]; then
					printf 'SET\\n%s\\n' "$PASSWORD" | /usr/bin/nc -w 2 -U "$SOCK" >/dev/null 2>&1
				fi
				printf '%s\\n' "$PASSWORD"
				exit 0
			fi
			MESSAGE="That password was not accepted. Try again.

		$REASON"
		done
		exit 1
		
		"""
	}
	
	/// The script's location, written on first use.
	private static var scriptURL: URL? {
		let url = directory.appendingPathComponent("askpass.sh")
		let contents = scriptContents
		
		if (try? String(contentsOf: url, encoding: .utf8)) != contents {
			do {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
				try contents.write(to: url, atomically: true, encoding: .utf8)
			} catch {
				return nil
			}
		}
		try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
		try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
		return url
	}
	
	/// Environment that makes `sudo` use the dialog. Empty if the script could not be written. `reason` is shown in the dialog.
	static func environment(reason: String) -> [String: String] {
		guard let url = scriptURL else { return [:] }
		try? reason.write(to: reasonURL, atomically: true, encoding: .utf8)
		SessionPasswordServer.shared.startIfNeeded()
		return ["SUDO_ASKPASS": url.path]
	}
	
}

/// Serves the session password to the askpass script over a Unix socket in the user's private folder.
///
/// Protocol: a client sends `GET` and receives the password (or nothing), or sends `SET` and the password on the next line.
final class SessionPasswordServer: @unchecked Sendable {
	
	static let shared = SessionPasswordServer()
	
	private let queue = DispatchQueue(label: "SessionPasswordServer")
	private var listener: DispatchSourceRead?
	private var password: String?
	private var expiry: Date?
	
	/// How long a kept password stays valid.
	private static let lifetime: TimeInterval = 30 * 60
	
	func startIfNeeded() {
		queue.sync {
			guard listener == nil else { return }
			
			let path = AskpassHelper.socketURL.path
			unlink(path)
			
			let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
			guard descriptor >= 0 else { return }
			
			var address = sockaddr_un()
			address.sun_family = sa_family_t(AF_UNIX)
			let capacity = MemoryLayout.size(ofValue: address.sun_path)
			guard path.utf8.count < capacity else { close(descriptor); return }
			withUnsafeMutablePointer(to: &address.sun_path) {
				$0.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
			}
			
			let bound = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
			}
			guard bound == 0, listen(descriptor, 8) == 0 else { close(descriptor); return }
			chmod(path, 0o600)
			
			let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
			source.setEventHandler { [weak self] in
				let client = accept(descriptor, nil, nil)
				if client >= 0 { self?.handle(client) }
			}
			source.setCancelHandler { close(descriptor); unlink(path) }
			source.resume()
			listener = source
		}
	}
	
	/// Forgets the password and closes the socket.
	func stop() {
		queue.sync {
			password = nil
			listener?.cancel()
			listener = nil
		}
	}
	
	private func handle(_ client: Int32) {
		defer { close(client) }
		
		// Only this user may talk to the server.
		var uid: uid_t = 0, gid: gid_t = 0
		guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
		
		var timeout = timeval(tv_sec: 2, tv_usec: 0)
		setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
		
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 1024)
		while data.count < 4096 {
			let count = read(client, &buffer, buffer.count)
			if count <= 0 { break }
			data.append(buffer, count: count)
			// A SET carries two lines, a GET one.
			let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
			if lines.first == "GET" && lines.count > 1 { break }
			if lines.first == "SET" && lines.count > 2 { break }
		}
		
		let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
		switch lines.first {
		case "GET":
			if let expiry, expiry < Date() { password = nil }
			if let password {
				let reply = Array((password + "\n").utf8)
				_ = write(client, reply, reply.count)
			}
		case "SET" where lines.count > 2 && !lines[1].isEmpty:
			password = lines[1]
			expiry = Date().addingTimeInterval(Self.lifetime)
		default:
			break
		}
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
