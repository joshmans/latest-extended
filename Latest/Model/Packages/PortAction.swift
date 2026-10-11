//
//  PortAction.swift
//  Latest
//
//  This file is compiled into both the app and the privileged helper. It must only depend on Foundation.
//

import Foundation

/// The only things that may ever be run as root through the `port` command.
///
/// Both the prompting fallback and the privileged helper accept nothing but these shapes. The helper re-validates every request it receives with `init(arguments:)`, so a compromised or buggy client cannot make it run anything else.
enum PortAction: Equatable {
	
	/// Refreshes the port index.
	case selfUpdate
	
	/// Installs ports. With `binaryOnly` (`-b`) it fails instead of compiling when no prebuilt archive exists.
	case install(ports: [String], variants: [String], binaryOnly: Bool)
	
	/// Upgrades ports from prebuilt archives only.
	case upgrade(ports: [String])
	
	/// Uninstalls one port.
	case uninstall(port: String)
	
	
	// MARK: - Validation
	
	/// The largest number of ports in a single action.
	static let maximumPorts = 200
	
	/// Whether a name is safe to pass to the `port` command.
	static func isValidPortName(_ name: String) -> Bool {
		name.count <= 100 && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil
	}
	
	/// Whether a string is a single variant such as `+x11` or `-quartz`.
	static func isValidVariant(_ variant: String) -> Bool {
		variant.count <= 60 && variant.range(of: "^[+-][A-Za-z0-9_]+$", options: .regularExpression) != nil
	}
	
	
	// MARK: - Arguments
	
	/// The arguments for the `port` command, or `nil` if the action is not valid.
	var arguments: [String]? {
		switch self {
		case .selfUpdate:
			return ["-N", "selfupdate"]
			
		case .install(let ports, let variants, let binaryOnly):
			guard Self.areValid(ports: ports), variants.allSatisfy(Self.isValidVariant),
				  variants.isEmpty || ports.count == 1 else { return nil }
			// -p continues with the remaining ports if one fails.
			return ["-N", "-p"] + (binaryOnly ? ["-b"] : []) + ["install"] + ports + variants
			
		case .upgrade(let ports):
			guard Self.areValid(ports: ports) else { return nil }
			return ["-N", "-b", "upgrade"] + ports
			
		case .uninstall(let port):
			guard Self.isValidPortName(port) else { return nil }
			return ["-N", "uninstall", port]
		}
	}
	
	private static func areValid(ports: [String]) -> Bool {
		!ports.isEmpty && ports.count <= maximumPorts && ports.allSatisfy(isValidPortName)
	}
	
	/// Parses an argument vector back into an action. Returns `nil` for anything that is not exactly one of the allowed shapes.
	init?(arguments: [String]) {
		var rest = arguments[...]
		guard rest.first == "-N" else { return nil }
		rest = rest.dropFirst()
		
		if rest == ["selfupdate"] {
			self = .selfUpdate
			return
		}
		
		if rest.first == "-b", rest.dropFirst().first == "upgrade" {
			let action = PortAction.upgrade(ports: Array(rest.dropFirst(2)))
			guard action.arguments == arguments else { return nil }
			self = action
			return
		}
		
		if rest.first == "uninstall", rest.count == 2 {
			let action = PortAction.uninstall(port: rest[rest.startIndex + 1])
			guard action.arguments == arguments else { return nil }
			self = action
			return
		}
		
		if rest.first == "-p" {
			rest = rest.dropFirst()
			var binaryOnly = false
			if rest.first == "-b" { binaryOnly = true; rest = rest.dropFirst() }
			guard rest.first == "install" else { return nil }
			let tail = Array(rest.dropFirst())
			let ports = Array(tail.prefix { !$0.hasPrefix("+") && !$0.hasPrefix("-") })
			let variants = Array(tail.dropFirst(ports.count))
			let action = PortAction.install(ports: ports, variants: variants, binaryOnly: binaryOnly)
			guard action.arguments == arguments else { return nil }
			self = action
			return
		}
		
		return nil
	}
	
}
