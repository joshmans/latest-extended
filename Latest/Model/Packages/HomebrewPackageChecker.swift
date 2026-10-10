//
//  HomebrewPackageChecker.swift
//  Latest
//

import Foundation

/// Decides whether Homebrew has a prebuilt bottle for a given machine.
enum HomebrewBottles {
	
	private static let releaseNames: [(major: Int, name: String)] = [
		(27, "golden_gate"), (26, "tahoe"), (15, "sequoia"), (14, "sonoma"), (13, "ventura"), (12, "monterey"), (11, "big_sur")
	]
	
	/// The bottle tags usable on the given system, newest first. Homebrew falls back to bottles built for older macOS releases.
	static func usableTags(arm64: Bool, macOSMajor: Int) -> [String] {
		let prefix = arm64 ? "arm64_" : ""
		return releaseNames.filter { $0.major <= macOSMajor }.map { prefix + $0.name } + ["all"]
	}
	
	static func hasBottle(files: Set<String>, arm64: Bool, macOSMajor: Int) -> Bool {
		!files.isDisjoint(with: usableTags(arm64: arm64, macOSMajor: macOSMajor))
	}
	
}

/// Finds outdated Homebrew formulae and checks whether they can be installed without compiling.
enum HomebrewPackageChecker {
	
	private static let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
	
	static func check(arm64: Bool = SystemInfo.isARM, macOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> [PackageUpdate] {
		guard let brew = HomebrewUpdateOperation.brewURL?.path else { return [] }
		
		let outdated = CommandRunner.run(brew, ["outdated", "--formula", "--json=v2"], environment: environment)
		guard let root = json(outdated.output)?["formulae"] as? [[String: Any]], !root.isEmpty else { return [] }
		
		let names = root.compactMap { $0["name"] as? String }
		let info = CommandRunner.run(brew, ["info", "--formula", "--json=v2"] + names, environment: environment)
		let details = Dictionary(uniqueKeysWithValues: ((json(info.output)?["formulae"] as? [[String: Any]]) ?? []).compactMap { entry -> (String, [String: Any])? in
			guard let name = entry["name"] as? String else { return nil }
			return (name, entry)
		})
		
		func hasBottle(_ name: String) -> Bool {
			let stable = ((details[name]?["bottle"] as? [String: Any])?["stable"] as? [String: Any])
			let files = Set((stable?["files"] as? [String: Any])?.keys.map { $0 } ?? [])
			return HomebrewBottles.hasBottle(files: files, arm64: arm64, macOSMajor: macOSMajor)
		}
		
		let outdatedNames = Set(names)
		return root.compactMap { entry in
			guard let name = entry["name"] as? String else { return nil }
			let installed = (entry["installed_versions"] as? [String])?.last ?? "?"
			let available = entry["current_version"] as? String ?? "?"
			
			var state = PackageUpdate.State.prebuilt
			if !hasBottle(name) {
				state = .wouldCompile(reason: "No prebuilt bottle for this Mac")
			} else if let dependencies = details[name]?["dependencies"] as? [String],
					  let blocker = dependencies.first(where: { outdatedNames.contains($0) && !hasBottle($0) }) {
				state = .wouldCompile(reason: "Needs \(blocker), which has no prebuilt bottle")
			}
			
			return PackageUpdate(manager: .homebrew, name: name, installedVersion: installed, availableVersion: available, state: state)
		}
	}
	
	/// The arguments for upgrading the given formulae from bottles.
	static func upgradeArguments(for names: [String]) -> [String] {
		["upgrade", "--formula", "--force-bottle"] + names
	}
	
	static func upgrade(_ names: [String]) -> CommandRunner.Result {
		guard let brew = HomebrewUpdateOperation.brewURL?.path else {
			return .init(status: -1, output: "Homebrew is not installed.")
		}
		return CommandRunner.run(brew, upgradeArguments(for: names), environment: environment)
	}
	
	/// Installed formulae that depend on the given formula.
	static func dependents(of name: String) -> [String] {
		guard let brew = HomebrewUpdateOperation.brewURL?.path else { return [] }
		let result = CommandRunner.run(brew, ["uses", "--installed", "--formula", name], environment: environment)
		return result.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Warning") && !$0.hasPrefix("Error") && !$0.contains(" ") }
	}
	
	/// For each installed formula, the installed formulae that depend on it at runtime. One call instead of a slow `brew uses` per formula.
	static func reverseDependencies() -> [String: [String]] {
		guard let brew = HomebrewUpdateOperation.brewURL?.path else { return [:] }
		let result = CommandRunner.run(brew, ["info", "--json=v2", "--installed", "--formula"], environment: environment)
		return reverseDependencies(fromInfoJSON: result.output)
	}
	
	static func reverseDependencies(fromInfoJSON output: String) -> [String: [String]] {
		guard let formulae = json(output)?["formulae"] as? [[String: Any]] else { return [:] }
		var reverse = [String: [String]]()
		for formula in formulae {
			guard let name = formula["name"] as? String,
				  let installed = (formula["installed"] as? [[String: Any]])?.last,
				  let dependencies = installed["runtime_dependencies"] as? [[String: Any]] else { continue }
			for dependency in dependencies.compactMap({ $0["full_name"] as? String }) {
				reverse[dependency, default: []].append(name)
			}
		}
		return reverse
	}
	
	/// Environment for removals. Without this, Homebrew silently removes other "unneeded" formulae too, which would remove things the user did not choose.
	static let uninstallEnvironment = environment.merging(["HOMEBREW_NO_AUTOREMOVE": "1"]) { $1 }
	
	/// Whether the formula is currently installed.
	static func isInstalled(_ name: String) -> Bool {
		guard let brew = HomebrewUpdateOperation.brewURL?.path else { return false }
		return CommandRunner.run(brew, ["list", "--formula", "--versions", name], environment: environment).output
			.split(separator: "\n").contains { $0.hasPrefix(name + " ") }
	}
	
	/// Uninstalls a formula. Homebrew itself refuses if other formulae still depend on it, and this never passes `--force` or `--ignore-dependencies`.
	static func uninstall(_ name: String) -> CommandRunner.Result {
		guard let brew = HomebrewUpdateOperation.brewURL?.path else { return .init(status: -1, output: "Homebrew is not installed.") }
		return CommandRunner.run(brew, ["uninstall", "--formula", name], environment: uninstallEnvironment)
	}
	
	static func refreshIndex() -> CommandRunner.Result {
		guard let brew = HomebrewUpdateOperation.brewURL?.path else { return .init(status: -1, output: "Homebrew is not installed.") }
		return CommandRunner.run(brew, ["update"], environment: ["HOMEBREW_NO_ENV_HINTS": "1"])
	}
	
	static func json(_ output: String) -> [String: Any]? {
		// Skip any warnings printed before the JSON document.
		guard let start = output.firstIndex(of: "{"), let data = String(output[start...]).data(using: .utf8) else { return nil }
		return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
	}
	
}

/// Information about the machine the app runs on.
enum SystemInfo {
	
	static var isARM: Bool { machine == "arm64" }
	
	static var machine: String {
		var info = utsname()
		uname(&info)
		return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
	}
	
	/// The Darwin kernel major version, which MacPorts uses in archive names (25 for macOS 26).
	static var darwinMajor: Int {
		var info = utsname()
		uname(&info)
		let release = withUnsafeBytes(of: &info.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		return Int(release.split(separator: ".").first ?? "") ?? 0
	}
	
}
