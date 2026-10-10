//
//  MacPortsSupport.swift
//  Latest
//

import Foundation

/// Parsing and naming helpers for MacPorts. Pure functions, so they can be tested without MacPorts.
enum MacPortsParser {
	
	struct Outdated: Equatable {
		let name: String
		let installed: String
		let available: String
	}
	
	/// Parses `port outdated` output, lines look like `aom   3.14.1_0 < 3.15.1_0`.
	static func parseOutdated(_ output: String) -> [Outdated] {
		output.split(separator: "\n").compactMap { line in
			let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
			guard parts.count == 4, parts[2] == "<" else { return nil }
			return Outdated(name: String(parts[0]), installed: String(parts[1]), available: String(parts[3]))
		}
	}
	
	/// Returns the variants (e.g. `+quartz+x11`) of the active installation of a port from `port installed <name>` output.
	static func activeVariants(in installedOutput: String, name: String) -> String {
		for line in installedOutput.split(separator: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard trimmed.hasPrefix(name + " @"), trimmed.hasSuffix("(active)") else { continue }
			let version = trimmed.dropFirst(name.count + 2).split(separator: " ").first ?? ""
			if let plus = version.firstIndex(of: "+") { return String(version[plus...]) }
			return ""
		}
		return ""
	}
	
	/// The URL of the prebuilt archive for a port version on the given system.
	static func archiveURL(name: String, version: String, variants: String, darwin: Int, arch: String) -> URL? {
		let file = "\(name)-\(version)\(variants).darwin_\(darwin).\(arch).tbz2"
		return URL(string: "https://packages.macports.org/\(name)/")?.appendingPathComponent(file)
	}
	
	/// Whether a name is safe to pass to the port command.
	static func isValidPortName(_ name: String) -> Bool {
		name.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil
	}
	
	/// Candidate MacPorts names for a Homebrew formula name.
	static func candidateNames(forHomebrewFormula name: String) -> [String] {
		var names = [name, name.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: ".", with: ""), name.replacingOccurrences(of: "+", with: "")]
		names.append(name.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "+", with: ""))
		if name.hasPrefix("python-tk@") {
			names.append("py" + name.dropFirst("python-tk@".count).replacingOccurrences(of: ".", with: "") + "-tkinter")
		}
		if name == "qt" { names.append("qt6") }
		if name.hasPrefix("qt"), name != "qt" { names.append("qt6-" + name) }
		var seen = Set<String>()
		return names.filter { seen.insert($0).inserted }
	}
	
	/// Finds the newest archive for a port that works on the given system in a `packages.macports.org/<port>/` directory listing.
	///
	/// Architecture independent ports (pure Python or scripts) are published as `darwin_any.noarch` and work everywhere.
	static func newestArchiveVersion(inListing html: String, port: String, darwin: Int, arch: String) -> String? {
		let suffixes = [".darwin_\(darwin).\(arch).tbz2", ".darwin_any.noarch.tbz2"]
		let prefix = "\(port)-"
		var found = [String]()
		var rest = html[...]
		while let range = rest.range(of: "href=\"") {
			rest = rest[range.upperBound...]
			guard let end = rest.firstIndex(of: "\"") else { break }
			let file = String(rest[..<end])
			if file.hasPrefix(prefix), let suffix = suffixes.first(where: file.hasSuffix) {
				found.append(String(file.dropFirst(prefix.count).dropLast(suffix.count)))
			}
		}
		return found.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
	}
	
	/// The URLs a prebuilt archive for a port version can have on the given system: architecture specific, or architecture independent.
	static func archiveURLs(name: String, version: String, variants: String, darwin: Int, arch: String) -> [URL] {
		let base = URL(string: "https://packages.macports.org/\(name)/")
		return ["darwin_\(darwin).\(arch)", "darwin_any.noarch"].compactMap {
			base?.appendingPathComponent("\(name)-\(version)\(variants).\($0).tbz2")
		}
	}
	
}

/// Finds outdated MacPorts ports and checks whether prebuilt archives exist for them.
enum MacPortsPackageChecker {
	
	static let portPath = "/opt/local/bin/port"
	
	static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: portPath) }
	
	struct Report {
		var updates: [PackageUpdate]
		
		/// Whether the local port index is old, which means newer versions may be missing from the results.
		var indexIsStale: Bool
	}
	
	static func check() -> Report {
		guard isInstalled else { return Report(updates: [], indexIsStale: false) }
		
		let outdated = CommandRunner.run(portPath, ["outdated"])
		let stale = outdated.output.contains("more than two weeks old")
		let darwin = SystemInfo.darwinMajor
		let arch = SystemInfo.machine
		
		let updates = MacPortsParser.parseOutdated(outdated.output).map { entry -> PackageUpdate in
			let installed = CommandRunner.run(portPath, ["installed", entry.name]).output
			let variants = MacPortsParser.activeVariants(in: installed, name: entry.name)
			
			var state = PackageUpdate.State.wouldCompile(reason: "No prebuilt archive for this Mac yet")
			if MacPortsParser.archiveURLs(name: entry.name, version: entry.available, variants: variants, darwin: darwin, arch: arch).contains(where: Network.exists) {
				state = .prebuilt
			}
			return PackageUpdate(manager: .macPorts, name: entry.name, installedVersion: entry.installed, availableVersion: entry.available, state: state)
		}
		
		return Report(updates: updates, indexIsStale: stale)
	}
	
	/// Looks for a prebuilt MacPorts equivalent of a Homebrew formula.
	static func equivalent(forHomebrewFormula name: String) -> PackageUpdate.Alternative? {
		let darwin = SystemInfo.darwinMajor
		let arch = SystemInfo.machine
		
		for candidate in MacPortsParser.candidateNames(forHomebrewFormula: name) where MacPortsParser.isValidPortName(candidate) {
			guard let url = URL(string: "https://packages.macports.org/\(candidate)/"), let html = Network.get(url),
				  let version = MacPortsParser.newestArchiveVersion(inListing: html, port: candidate, darwin: darwin, arch: arch) else { continue }
			return PackageUpdate.Alternative(manager: .macPorts, name: candidate, version: version)
		}
		return nil
	}
	
	/// Upgrades the given ports using prebuilt archives only (`-b` fails instead of compiling).
	static func upgrade(_ names: [String]) -> CommandRunner.Result {
		let valid = names.filter(MacPortsParser.isValidPortName)
		guard !valid.isEmpty else { return .init(status: -1, output: "No valid port names given.") }
		return CommandRunner.runAsAdministrator(portPath, ["-N", "-b", "upgrade"] + valid)
	}
	
	/// Installs ports. By default only prebuilt archives are used (`-b`); `buildFromSource` allows compiling.
	static func install(_ names: [String], variants: String = "", buildFromSource: Bool = false) -> CommandRunner.Result {
		let valid = names.filter(MacPortsParser.isValidPortName)
		guard !valid.isEmpty, valid.count == names.count, MacPortsParser.isValidVariantSelection(variants) else {
			return .init(status: -1, output: "Invalid port name or variants.")
		}
		let variantArguments = variants.split(separator: " ").map(String.init)
		// -p continues with the remaining ports if one fails.
		var arguments = ["-N", "-p"] + (buildFromSource ? [] : ["-b"]) + ["install"]
		for name in valid { arguments.append(name); if valid.count == 1 { arguments += variantArguments } }
		return CommandRunner.runAsAdministrator(portPath, arguments)
	}
	
	static func uninstall(_ name: String) -> CommandRunner.Result {
		guard MacPortsParser.isValidPortName(name) else { return .init(status: -1, output: "Invalid port name.") }
		return CommandRunner.runAsAdministrator(portPath, ["-N", "uninstall", name])
	}
	
	/// The ports whose local index version differs from the prebuilt archive on the server. Installing those with `-b` would fail until the index is refreshed.
	static func portsWithOutdatedIndex(_ archiveVersions: [String: String]) -> [String] {
		archiveVersions.compactMap { port, archive in
			let info = MacPortsParser.parseInfo(CommandRunner.run(portPath, ["info", "--index", "--version", "--revision", port]).output)
			guard let version = info["version"], let revision = info["revision"] else { return nil }
			return MacPortsParser.archiveMatchesIndex(archiveVersion: archive, indexVersion: version, indexRevision: revision) ? nil : port
		}.sorted()
	}
	
	/// Whether the port is currently installed and active.
	static func isActive(_ name: String) -> Bool {
		MacPortsParser.parseInstalled(CommandRunner.run(portPath, ["installed", name]).output).contains { $0.name == name && $0.isActive }
	}
	
	/// Refreshes the port index.
	static func selfUpdate() -> CommandRunner.Result {
		CommandRunner.runAsAdministrator(portPath, ["-N", "selfupdate"])
	}
	
}

/// Minimal synchronous HTTP helpers for background threads.
enum Network {
	
	static func get(_ url: URL) -> String? {
		fetch(url, method: "GET").flatMap { String(data: $0, encoding: .utf8) }
	}
	
	static func exists(_ url: URL) -> Bool {
		fetch(url, method: "HEAD") != nil
	}
	
	private static func fetch(_ url: URL, method: String) -> Data? {
		var request = URLRequest(url: url, timeoutInterval: 20)
		request.httpMethod = method
		var result: Data?
		let semaphore = DispatchSemaphore(value: 0)
		URLSession.shared.dataTask(with: request) { data, response, _ in
			if (response as? HTTPURLResponse)?.statusCode == 200 { result = data ?? Data() }
			semaphore.signal()
		}.resume()
		semaphore.wait()
		return result
	}
	
}
