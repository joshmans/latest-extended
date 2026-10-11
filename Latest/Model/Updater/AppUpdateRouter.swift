//
//  AppUpdateRouter.swift
//  Latest
//

import Cocoa

/// The ways an app update found through a Homebrew cask can be carried out.
enum AppUpdateRoute: Equatable {
	/// Upgrade the cask Homebrew already manages.
	case homebrewUpgrade
	/// Install the cask over an app Homebrew does not manage. Homebrew manages it from then on.
	case homebrewInstall
	/// Install the prebuilt MacPorts port of the app. It lands in /Applications/MacPorts and does not replace the current copy.
	case macPorts(port: String)
}

/// Decides how to update an app and asks the user before taking over an app Homebrew did not install.
enum AppUpdateRouter {
	
	/// The routes to offer, best first. Managed casks are simply upgraded. Otherwise MacPorts is preferred when it is installed, on an Intel Mac and has a prebuilt port.
	static func routes(isManaged: Bool, macPortsInstalled: Bool, isARM: Bool, macPortsPort: String?) -> [AppUpdateRoute] {
		if isManaged { return [.homebrewUpgrade] }
		
		guard macPortsInstalled, let port = macPortsPort else { return [.homebrewInstall] }
		return isARM ? [.homebrewInstall, .macPorts(port: port)] : [.macPorts(port: port), .homebrewInstall]
	}
	
	/// Routes the user chose to remember for the rest of this session, so Update All asks once.
	private static var rememberedKind: String?
	private static var inProgress = Set<App.Bundle.Identifier>()
	
	private static func kind(_ route: AppUpdateRoute) -> String {
		if case .macPorts = route { return "macports" }
		return "homebrew"
	}
	
	static func start(app: App.Bundle, caskToken: String, appName: String) {
		let identifier = app.identifier
		guard !inProgress.contains(identifier) else { return }
		inProgress.insert(identifier)
		
		DispatchQueue.global().async {
			let isManaged = HomebrewUpdateOperation.brewURL.map { brew in
				CommandRunner.run(brew.path, ["list", "--cask", caskToken], environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]).status == 0
			} ?? false
			
			let installed = MacPortsPackageChecker.isInstalled
			let port = (!isManaged && installed) ? MacPortsPackageChecker.equivalent(forHomebrewFormula: caskToken)?.name : nil
			let routes = routes(isManaged: isManaged, macPortsInstalled: installed, isARM: SystemInfo.isARM, macPortsPort: port)
			
			DispatchQueue.main.async {
				defer { inProgress.remove(identifier) }
				
				if routes == [.homebrewUpgrade] {
					enqueue(.homebrewUpgrade, app: app, caskToken: caskToken)
				} else if let remembered = rememberedKind, let route = routes.first(where: { kind($0) == remembered }) {
					enqueue(route, app: app, caskToken: caskToken)
				} else {
					switch ask(routes, appName: appName, caskToken: caskToken) {
					case .route(let route)?:
						enqueue(route, app: app, caskToken: caskToken)
					case .ignore?:
						UpdateLog.write("[\(caskToken)] ignored by the user")
						if let known = UpdateCheckCoordinator.shared.appProvider.app(withIdentifier: app.identifier) {
							UpdateCheckCoordinator.shared.appProvider.setIgnoredState(true, for: known)
						}
					case nil:
						break
					}
				}
			}
		}
	}
	
	private enum Choice {
		case route(AppUpdateRoute)
		case ignore
	}
	
	private static func ask(_ routes: [AppUpdateRoute], appName: String, caskToken: String) -> Choice? {
		let alert = NSAlert()
		alert.messageText = "Update \(appName)?"
		var details = "\(appName) was not installed with Homebrew, so Latest will not replace it silently."
		var buttons = [(String, Choice?)]()
		for route in routes {
			switch route {
			case .homebrewInstall:
				details += "\n\n• Homebrew: installs the \(caskToken) cask over your current copy. Homebrew manages the app from then on."
				buttons.append(("Install with Homebrew", .route(route)))
			case .macPorts(let port):
				details += "\n\n• MacPorts: installs the prebuilt port \(port) into /Applications/MacPorts. Your current copy stays as it is."
				buttons.append(("Install with MacPorts", .route(route)))
			case .homebrewUpgrade:
				break
			}
		}
		if routes.count > 1 {
			details += "\n\nMacPorts is first because it is installed and this is an Intel Mac, where Homebrew no longer builds binaries."
		}
		buttons.append(("Cancel", nil))
		buttons.append(("Ignore This App", .ignore))
		alert.informativeText = details
		buttons.forEach { alert.addButton(withTitle: $0.0) }
		alert.showsSuppressionButton = true
		alert.suppressionButton?.title = "Use this choice for the other apps in this session"
		
		let response = alert.runModal()
		let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
		guard index >= 0, index < buttons.count, let choice = buttons[index].1 else { return nil }
		if case .route(let route) = choice, alert.suppressionButton?.state == .on { rememberedKind = kind(route) }
		return choice
	}
	
	private static func enqueue(_ route: AppUpdateRoute, app: App.Bundle, caskToken: String) {
		switch route {
		case .homebrewUpgrade:
			UpdateLog.write("[\(caskToken)] update requested for \(app.bundleIdentifier)")
			UpdateQueue.shared.addOperation(HomebrewUpdateOperation(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier, caskToken: caskToken))
		case .homebrewInstall:
			UpdateLog.write("[\(caskToken)] install requested for unmanaged \(app.bundleIdentifier) (confirmed)")
			UpdateQueue.shared.addOperation(HomebrewUpdateOperation(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier, caskToken: caskToken, adoptsApp: true))
		case .macPorts(let port):
			UpdateLog.write("[\(port)] MacPorts install requested for \(app.bundleIdentifier) (confirmed)")
			UpdateQueue.shared.addOperation(MacPortsInstallOperation(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier, port: port))
		}
	}
	
}

/// Installs the prebuilt MacPorts port of an app. Never compiles.
final class MacPortsInstallOperation: UpdateOperation, @unchecked Sendable {
	
	private let port: String
	
	init(bundleIdentifier: String, appIdentifier: App.Bundle.Identifier, port: String) {
		self.port = port
		super.init(bundleIdentifier: bundleIdentifier, appIdentifier: appIdentifier)
	}
	
	override func execute() {
		super.execute()
		UpdateLog.write("[\(port)] starting MacPorts install")
		progressState = .installing
		
		// A stale local index makes -b installs fail, so refresh it first when it disagrees with the prebuilt archive.
		var actions = [PortAction]()
		let archive = URL(string: "https://packages.macports.org/\(port)/").flatMap(Network.get).flatMap {
			MacPortsParser.newestArchiveVersion(inListing: $0, port: port, darwin: SystemInfo.darwinMajor, arch: SystemInfo.machine)
		}
		if let archive, !MacPortsPackageChecker.portsWithOutdatedIndex([port: archive]).isEmpty {
			actions.append(.selfUpdate)
		}
		actions.append(.install(ports: [port], variants: [], binaryOnly: true))
		
		let results = MacPortsPackageChecker.runBatch(actions)
		for result in results { UpdateLog.write("[\(port)] | \(result.output.suffix(800))") }
		
		if isCancelled {
			finish()
		} else if let failed = results.first(where: { $0.status != 0 }) {
			finish(with: LatestError.custom(title: "MacPorts could not install this app", description: String(failed.output.suffix(600))))
		} else {
			UpdateLog.write("[\(port)] exit 0")
			finish()
		}
	}
	
}
