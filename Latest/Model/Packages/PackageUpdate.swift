//
//  PackageUpdate.swift
//  Latest
//

import Foundation

/// An outdated command line package managed by Homebrew or MacPorts.
struct PackageUpdate: Hashable {
	
	enum Manager: String {
		case homebrew = "Homebrew"
		case macPorts = "MacPorts"
	}
	
	/// Whether the update can be installed without compiling anything.
	enum State: Hashable {
		/// A prebuilt binary exists for this machine.
		case prebuilt
		
		/// Installing would compile from source, so no update is offered.
		case wouldCompile(reason: String)
		
		var isPrebuilt: Bool {
			if case .prebuilt = self { return true }
			return false
		}
	}
	
	/// A prebuilt equivalent of a blocked package in the other package manager.
	struct Alternative: Hashable {
		let manager: Manager
		let name: String
		let version: String
	}
	
	let manager: Manager
	let name: String
	let installedVersion: String
	let availableVersion: String
	let state: State
	var alternative: Alternative?
	
}

/// Compares package versions as they appear in Homebrew (`1.25.0_2`) and MacPorts (`1.25.0_1+gnutls`).
enum PackageVersions {
	
	enum Relation {
		case newer, same, older
	}
	
	/// The version without Homebrew revisions (`_2`), MacPorts revisions and variants (`_1+gnutls`).
	static func base(_ version: String) -> String {
		String(version.prefix { $0 != "_" && $0 != "+" })
	}
	
	/// How `candidate` relates to `reference`, comparing numbers numerically (`10` is newer than `9`).
	static func relation(of candidate: String, to reference: String) -> Relation {
		switch base(candidate).compare(base(reference), options: .numeric) {
		case .orderedDescending: return .newer
		case .orderedAscending: return .older
		case .orderedSame: return .same
		}
	}
	
}

extension PackageUpdate.Alternative {
	
	/// How this equivalent's version relates to a version you have or could get.
	func relation(to version: String) -> PackageVersions.Relation {
		PackageVersions.relation(of: self.version, to: version)
	}
	
}
