//
//  MacPortsBrowsing.swift
//  Latest
//

import Foundation

/// A port as listed by `port search` or `port installed`.
struct PortSummary: Hashable {
	let name: String
	let version: String
	let categories: [String]
	let summary: String
	var installedVersion: String?
	var isRequested = false
}

extension MacPortsParser {
	
	/// Parses `port search --line` output: `name<TAB>version<TAB>categories<TAB>description`.
	static func parseSearch(_ output: String) -> [PortSummary] {
		output.split(separator: "\n").compactMap { line in
			guard !line.hasPrefix("Warning:"), !line.hasPrefix("No match") else { return nil }
			let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
			guard fields.count >= 3, isValidPortName(String(fields[0])) else { return nil }
			return PortSummary(name: String(fields[0]), version: String(fields[1]), categories: fields[2].split(separator: " ").map(String.init), summary: fields.count > 3 ? String(fields[3]) : "")
		}
	}
	
	/// Parses `port installed` output into name → versions (with variants), marking the active one.
	static func parseInstalled(_ output: String) -> [(name: String, version: String, isActive: Bool)] {
		output.split(separator: "\n").compactMap { line in
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard let at = trimmed.firstIndex(of: "@"), trimmed.hasPrefix("The ") == false else { return nil }
			let name = trimmed[..<at].trimmingCharacters(in: .whitespaces)
			guard isValidPortName(name) else { return nil }
			let rest = trimmed[trimmed.index(after: at)...]
			let version = rest.split(separator: " ").first.map(String.init) ?? ""
			return (name, version, rest.contains("(active)"))
		}
	}
	
	/// Parses `port info --index` output (`key: value` lines).
	static func parseInfo(_ output: String) -> [String: String] {
		var result = [String: String]()
		for line in output.split(separator: "\n") where !line.hasPrefix("Warning:") {
			guard let colon = line.firstIndex(of: ":") else { continue }
			result[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
		}
		return result
	}
	
	/// Whether the string is a valid variant selection such as `+x11 -quartz`.
	static func isValidVariantSelection(_ string: String) -> Bool {
		string.trimmingCharacters(in: .whitespaces).isEmpty
		|| string.range(of: "^([+-][A-Za-z0-9_]+)( [+-][A-Za-z0-9_]+)*$", options: .regularExpression) != nil
	}
	
}

/// Plans a one-click switch of Homebrew formulae to their MacPorts equivalents.
enum PackageSwitch {
	
	struct Plan {
		/// Packages whose Homebrew copy can be replaced.
		var toSwitch = [PackageUpdate]()
		
		/// Packages that other Homebrew formulae still need. Homebrew's copy stays untouched.
		var keptBecauseOfDependents = [(package: PackageUpdate, dependents: [String])]()
		
		/// Packages without a prebuilt MacPorts equivalent.
		var withoutAlternative = [PackageUpdate]()
	}
	
	static func plan(for packages: [PackageUpdate], dependents: [String: [String]]) -> Plan {
		var plan = Plan()
		for package in packages where package.manager == .homebrew {
			guard let alternative = package.alternative, MacPortsParser.isValidPortName(alternative.name) else {
				plan.withoutAlternative.append(package)
				continue
			}
			let users = dependents[package.name] ?? []
			if users.isEmpty {
				plan.toSwitch.append(package)
			} else {
				plan.keptBecauseOfDependents.append((package, users))
			}
		}
		return plan
	}
	
}
