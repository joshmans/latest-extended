//
//  PackageUpdateTest.swift
//  LatestTests
//

import XCTest
@testable import Latest

final class PackageUpdateTest: XCTestCase {
	
	// MARK: Homebrew bottles
	
	func testIntelMacOS26IgnoresArmOnlyBottles() {
		let files: Set<String> = ["arm64_tahoe", "arm64_sequoia", "arm64_linux", "x86_64_linux"]
		XCTAssertFalse(HomebrewBottles.hasBottle(files: files, arm64: false, macOSMajor: 26))
	}
	
	func testIntelFallsBackToOlderMacOSBottle() {
		XCTAssertTrue(HomebrewBottles.hasBottle(files: ["sonoma"], arm64: false, macOSMajor: 26))
		XCTAssertFalse(HomebrewBottles.hasBottle(files: ["tahoe"], arm64: false, macOSMajor: 15), "A newer macOS bottle must not be used")
	}
	
	func testArchitectureIndependentBottleAlwaysUsable() {
		XCTAssertTrue(HomebrewBottles.hasBottle(files: ["all"], arm64: false, macOSMajor: 26))
	}
	
	func testAppleSiliconUsesArmBottles() {
		XCTAssertTrue(HomebrewBottles.hasBottle(files: ["arm64_tahoe"], arm64: true, macOSMajor: 26))
		XCTAssertFalse(HomebrewBottles.hasBottle(files: ["tahoe"], arm64: true, macOSMajor: 26))
	}
	
	func testUpgradeNeverBuildsFromSourceFlags() {
		let arguments = HomebrewPackageChecker.upgradeArguments(for: ["wget"])
		XCTAssertTrue(arguments.contains("--force-bottle"))
		XCTAssertFalse(arguments.contains("--build-from-source"))
	}
	
	// MARK: MacPorts
	
	func testParsesOutdatedOutput() {
		let output = """
		Warning: port definitions are more than two weeks old, consider updating them by running 'port selfupdate'.
		The following installed ports are outdated:
		aom                            3.14.1_0 < 3.15.1_0
		cairo                          1.18.4_2+quartz+x11 < 1.18.6_0
		"""
		XCTAssertEqual(MacPortsParser.parseOutdated(output), [
			.init(name: "aom", installed: "3.14.1_0", available: "3.15.1_0"),
			.init(name: "cairo", installed: "1.18.4_2+quartz+x11", available: "1.18.6_0")
		])
		XCTAssertEqual(MacPortsParser.parseOutdated("No installed ports are outdated."), [])
	}
	
	func testReadsActiveVariants() {
		let output = """
		The following ports are currently installed:
		  cairo @1.18.3_0 
		  cairo @1.18.4_2+quartz+x11 (active)
		"""
		XCTAssertEqual(MacPortsParser.activeVariants(in: output, name: "cairo"), "+quartz+x11")
		XCTAssertEqual(MacPortsParser.activeVariants(in: "  aom @3.14.1_0 (active)", name: "aom"), "")
	}
	
	func testBuildsArchiveURL() {
		let url = MacPortsParser.archiveURL(name: "cairo", version: "1.18.6_0", variants: "+quartz+x11", darwin: 25, arch: "x86_64")
		XCTAssertEqual(url?.absoluteString, "https://packages.macports.org/cairo/cairo-1.18.6_0+quartz+x11.darwin_25.x86_64.tbz2")
	}
	
	func testRejectsUnsafePortNames() {
		XCTAssertTrue(MacPortsParser.isValidPortName("py313-tkinter"))
		XCTAssertTrue(MacPortsParser.isValidPortName("gtk3+x11"))
		XCTAssertFalse(MacPortsParser.isValidPortName("foo; rm -rf /"))
		XCTAssertFalse(MacPortsParser.isValidPortName("-N"))
		XCTAssertFalse(MacPortsParser.isValidPortName("a b"))
	}
	
	func testMapsHomebrewNamesToPortNames() {
		XCTAssertTrue(MacPortsParser.candidateNames(forHomebrewFormula: "python@3.13").contains("python313"))
		XCTAssertTrue(MacPortsParser.candidateNames(forHomebrewFormula: "gtk+3").contains("gtk3"))
		XCTAssertTrue(MacPortsParser.candidateNames(forHomebrewFormula: "qtbase").contains("qt6-qtbase"))
		XCTAssertTrue(MacPortsParser.candidateNames(forHomebrewFormula: "python-tk@3.12").contains("py312-tkinter"))
	}
	
	func testFindsNewestArchiveInListing() {
		let html = """
		<a href="rust-1.98.0_0.darwin_25.x86_64.tbz2">a</a>
		<a href="rust-1.99.0_0.darwin_25.x86_64.tbz2">b</a>
		<a href="rust-2.0.0_0.darwin_25.arm64.tbz2">c</a>
		<a href="rust-9.0.0_0.darwin_24.x86_64.tbz2">d</a>
		<a href="rust-1.99.0_0.darwin_25.x86_64.tbz2.sig">e</a>
		"""
		XCTAssertEqual(MacPortsParser.newestArchiveVersion(inListing: html, port: "rust", darwin: 25, arch: "x86_64"), "1.99.0_0")
		XCTAssertNil(MacPortsParser.newestArchiveVersion(inListing: html, port: "rust", darwin: 27, arch: "x86_64"))
	}
	
	func testNoarchArchivesCountAsPrebuilt() {
		let html = "<a href=\"yt-dlp-2026.08.19_0+ffmpeg+python314.darwin_any.noarch.tbz2\">a</a><a href=\"yt-dlp-2026.06.09_0+python314.darwin_any.noarch.tbz2\">b</a>"
		XCTAssertEqual(MacPortsParser.newestArchiveVersion(inListing: html, port: "yt-dlp", darwin: 25, arch: "x86_64"), "2026.08.19_0+ffmpeg+python314")
	}
	
	func testChecksBothArchitectureSpecificAndNoarchURLs() {
		let urls = MacPortsParser.archiveURLs(name: "pipx", version: "1.17.2_0", variants: "+python314", darwin: 25, arch: "x86_64").map(\.lastPathComponent)
		XCTAssertEqual(urls, ["pipx-1.17.2_0+python314.darwin_25.x86_64.tbz2", "pipx-1.17.2_0+python314.darwin_any.noarch.tbz2"])
	}
	
	func testDetectsStaleIndexAgainstArchives() {
		XCTAssertFalse(MacPortsParser.archiveMatchesIndex(archiveVersion: "2.9.7_0", indexVersion: "2.9.6", indexRevision: "0"))
		XCTAssertTrue(MacPortsParser.archiveMatchesIndex(archiveVersion: "2026.08.19_0+ffmpeg+python314", indexVersion: "2026.08.19", indexRevision: "0"))
		XCTAssertFalse(MacPortsParser.archiveMatchesIndex(archiveVersion: "1.2.10_0", indexVersion: "1.2.1", indexRevision: "0"), "A longer version must not match by prefix")
		XCTAssertFalse(MacPortsParser.archiveMatchesIndex(archiveVersion: "1.25.0_1+gnutls", indexVersion: "1.25.0", indexRevision: "0"))
	}
	
	func testUninstallNeverAutoremovesOtherFormulae() {
		XCTAssertEqual(HomebrewPackageChecker.uninstallEnvironment["HOMEBREW_NO_AUTOREMOVE"], "1")
	}
	
	func testShellQuoting() {
		XCTAssertEqual(CommandRunner.shellQuote("it's"), "'it'\\''s'")
	}
	
	// MARK: MacPorts browsing
	
	func testParsesSearchLines() {
		let output = "Warning: port definitions are more than two weeks old\nwget\t1.25.0\tnet www\tinternet file retriever\nwget2\t2.2.1\tnet www\tGNU Wget2\nNo match for xyz found"
		let results = MacPortsParser.parseSearch(output)
		XCTAssertEqual(results.map(\.name), ["wget", "wget2"])
		XCTAssertEqual(results.first?.categories, ["net", "www"])
		XCTAssertEqual(results.first?.summary, "internet file retriever")
	}
	
	func testParsesInstalledOutput() {
		let output = "The following ports are currently installed:\n  aom @3.14.1_0 (active)\n  cairo @1.18.3_0\n  cairo @1.18.4_2+quartz+x11 (active)"
		let parsed = MacPortsParser.parseInstalled(output)
		XCTAssertEqual(parsed.map(\.name), ["aom", "cairo", "cairo"])
		XCTAssertEqual(parsed.filter(\.isActive).map(\.version), ["3.14.1_0", "1.18.4_2+quartz+x11"])
	}
	
	func testParsesInfo() {
		let info = MacPortsParser.parseInfo("Warning: old\nfullname: wget @1.25.0\ncategory: net, www\ndescription: internet file retriever")
		XCTAssertEqual(info["fullname"], "wget @1.25.0")
		XCTAssertEqual(info["category"], "net, www")
	}
	
	func testValidatesVariantSelections() {
		XCTAssertTrue(MacPortsParser.isValidVariantSelection(""))
		XCTAssertTrue(MacPortsParser.isValidVariantSelection("+x11 -quartz"))
		XCTAssertFalse(MacPortsParser.isValidVariantSelection("+x11; reboot"))
		XCTAssertFalse(MacPortsParser.isValidVariantSelection("x11"))
	}
	
	// MARK: Switching
	
	private func brew(_ name: String, alternative: String?) -> PackageUpdate {
		PackageUpdate(manager: .homebrew, name: name, installedVersion: "1", availableVersion: "2", state: .wouldCompile(reason: "x"),
					  alternative: alternative.map { .init(manager: .macPorts, name: $0, version: "1") })
	}
	
	private let ports = ["aom": "aom", "ffmpeg": "ffmpeg", "deno": "deno", "yt-dlp": "yt-dlp", "gh": "gh", "imagemagick": "imagemagick"]
	
	func testSwitchPullsDependentsIntoTheGroupAndOrdersThemFirst() {
		let reverse = ["aom": ["ffmpeg"], "ffmpeg": ["imagemagick"]]
		let plan = PackageSwitch.plan(selected: [brew("aom", alternative: "aom")], reverseDependencies: reverse, alternative: { self.ports[$0] })
		XCTAssertEqual(plan.groups.count, 1)
		XCTAssertEqual(plan.groups.first?.formulae, ["imagemagick", "ffmpeg", "aom"])
		XCTAssertEqual(plan.groups.first?.pulledIn, ["ffmpeg", "imagemagick"])
		XCTAssertTrue(plan.blocked.isEmpty)
	}
	
	func testSwitchBlocksGroupWhenADependentHasNoEquivalent() {
		let plan = PackageSwitch.plan(selected: [brew("deno", alternative: "deno")], reverseDependencies: ["deno": ["yt-dlp"]], alternative: { $0 == "deno" ? "deno" : nil })
		XCTAssertTrue(plan.groups.isEmpty)
		XCTAssertEqual(plan.blocked.first?.package, "deno")
		XCTAssertTrue(plan.blocked.first?.reason.contains("yt-dlp") ?? false)
	}
	
	func testSwitchRefusesOversizedGroups() {
		let reverse = ["aom": (0..<30).map { "dep\($0)" }]
		let plan = PackageSwitch.plan(selected: [brew("aom", alternative: "aom")], reverseDependencies: reverse, alternative: { $0 })
		XCTAssertTrue(plan.groups.isEmpty)
		XCTAssertTrue(plan.blocked.first?.reason.contains("limit") ?? false)
	}
	
	func testOverlappingSelectionsMergeIntoOneGroup() {
		let plan = PackageSwitch.plan(selected: [brew("a", alternative: "a"), brew("b", alternative: "b")], reverseDependencies: ["a": ["shared"], "b": ["shared"]], alternative: { $0 })
		XCTAssertEqual(plan.groups.count, 1)
		XCTAssertEqual(Set(plan.groups[0].formulae), ["a", "b", "shared"])
		XCTAssertEqual(plan.groups[0].formulae.first, "shared")
	}
	
	func testIndependentPackagesStaySeparateGroups() {
		let plan = PackageSwitch.plan(selected: [brew("gh", alternative: "gh"), brew("deno", alternative: "deno")], reverseDependencies: [:], alternative: { self.ports[$0] })
		XCTAssertEqual(plan.groups.count, 2)
	}
	
	func testRejectsUnsafePortNameFromAlternative() {
		let plan = PackageSwitch.plan(selected: [brew("evil", alternative: "x")], reverseDependencies: [:], alternative: { _ in "x; rm -rf /" })
		XCTAssertTrue(plan.groups.isEmpty)
		XCTAssertEqual(plan.blocked.count, 1)
	}
	
	func testBuildsReverseDependenciesFromBrewJSON() {
		let json = """
		{"formulae":[
		 {"name":"aom","installed":[{"runtime_dependencies":[]}]},
		 {"name":"ffmpeg","installed":[{"runtime_dependencies":[{"full_name":"aom"},{"full_name":"x265"}]}]},
		 {"name":"yt-dlp","installed":[{"runtime_dependencies":[{"full_name":"deno"}]}]}
		]}
		"""
		let reverse = HomebrewPackageChecker.reverseDependencies(fromInfoJSON: json)
		XCTAssertEqual(reverse["aom"], ["ffmpeg"])
		XCTAssertEqual(reverse["deno"], ["yt-dlp"])
	}
}
