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
	
	/// Whether a prebuilt archive version (e.g. `2.9.7_0+ffmpeg`) is the version the local port index would install (`2.9.7`, revision `0`).
	static func archiveMatchesIndex(archiveVersion: String, indexVersion: String, indexRevision: String) -> Bool {
		let expected = "\(indexVersion)_\(indexRevision)"
		guard archiveVersion.hasPrefix(expected) else { return false }
		let rest = archiveVersion.dropFirst(expected.count)
		return rest.isEmpty || rest.first == "+"
	}
	
	/// Whether the string is a valid variant selection such as `+x11 -quartz`.
	static func isValidVariantSelection(_ string: String) -> Bool {
		string.trimmingCharacters(in: .whitespaces).isEmpty
		|| string.range(of: "^([+-][A-Za-z0-9_]+)( [+-][A-Za-z0-9_]+)*$", options: .regularExpression) != nil
	}
	
}

/// Plans a one-click switch of Homebrew formulae to their MacPorts equivalents, including everything that depends on them.
enum PackageSwitch {
	
	/// Formulae that must move together, because removing one from Homebrew requires removing everything that depends on it.
	struct Group {
		/// Formulae in the order Homebrew can uninstall them: dependents first.
		var formulae: [String]
		
		/// The MacPorts port that replaces each formula.
		var ports: [String: String]
		
		/// Formulae that were pulled in only because they depend on a selected one.
		var pulledIn: [String]
	}
	
	struct Plan {
		var groups = [Group]()
		
		/// Selected packages that cannot be switched, with the reason.
		var blocked = [(package: String, reason: String)]()
	}
	
	/// The largest group that will be switched in one go.
	static let maximumGroupSize = 25
	
	/// - Parameters:
	///   - selected: The Homebrew packages the user chose.
	///   - reverseDependencies: For each formula, the installed formulae that depend on it.
	///   - alternative: The prebuilt MacPorts port replacing a formula, if any.
	static func plan(selected: [PackageUpdate], reverseDependencies: [String: [String]], alternative: (String) -> String?, maximumGroupSize: Int = PackageSwitch.maximumGroupSize) -> Plan {
		var plan = Plan()
		let selectedNames = selected.filter { $0.manager == .homebrew }.map(\.name)
		
		// Everything that has to move together with each selected formula.
		var closures = [Set<String>]()
		for name in selectedNames {
			var closure: Set<String> = [name]
			var queue = [name]
			while let current = queue.popLast() {
				for dependent in reverseDependencies[current] ?? [] where closure.insert(dependent).inserted {
					queue.append(dependent)
				}
			}
			closures.append(closure)
		}
		
		// Merge closures that overlap, since removing one needs the other gone as well.
		var merged = [(members: Set<String>, selected: [String])]()
		for (index, closure) in closures.enumerated() {
			let overlapping = merged.indices.filter { !merged[$0].members.isDisjoint(with: closure) }
			var group = (members: closure, selected: [selectedNames[index]])
			for position in overlapping.reversed() {
				group.members.formUnion(merged[position].members)
				group.selected += merged[position].selected
				merged.remove(at: position)
			}
			merged.append(group)
		}
		
		for entry in merged {
			let names = entry.selected.sorted().joined(separator: ", ")
			if entry.members.count > maximumGroupSize {
				for name in entry.selected { plan.blocked.append((name, "It would pull in \(entry.members.count) packages (limit \(maximumGroupSize))")) }
				continue
			}
			
			var ports = [String: String]()
			var missing: String?
			for member in entry.members.sorted() {
				if let port = alternative(member), MacPortsParser.isValidPortName(port) { ports[member] = port } else { missing = member; break }
			}
			if let missing {
				let reason = entry.selected.contains(missing)
					? "No prebuilt MacPorts equivalent"
					: "\(missing) depends on it and has no prebuilt MacPorts equivalent"
				for name in entry.selected { plan.blocked.append((name, reason)) }
				_ = names
				continue
			}
			
			plan.groups.append(Group(formulae: uninstallOrder(entry.members, reverseDependencies), ports: ports, pulledIn: entry.members.subtracting(entry.selected).sorted()))
		}
		return plan
	}
	
	/// Orders formulae so each one comes after everything in the set that depends on it.
	static func uninstallOrder(_ members: Set<String>, _ reverseDependencies: [String: [String]]) -> [String] {
		var remaining = members
		var ordered = [String]()
		while !remaining.isEmpty {
			let ready = remaining.filter { name in (reverseDependencies[name] ?? []).allSatisfy { !remaining.contains($0) } }.sorted()
			guard !ready.isEmpty else { ordered += remaining.sorted(); break }
			ordered += ready
			remaining.subtract(ready)
		}
		return ordered
	}
	
}
