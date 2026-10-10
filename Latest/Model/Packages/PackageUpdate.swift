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
