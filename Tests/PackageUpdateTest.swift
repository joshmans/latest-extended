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
	
	func testSwitchKeepsFormulaeThatOthersDependOn() {
		let plan = PackageSwitch.plan(for: [brew("aom", alternative: "aom"), brew("deno", alternative: "deno")], dependents: ["aom": ["ffmpeg"], "deno": []])
		XCTAssertEqual(plan.toSwitch.map(\.name), ["deno"])
		XCTAssertEqual(plan.keptBecauseOfDependents.map(\.package.name), ["aom"])
		XCTAssertEqual(plan.keptBecauseOfDependents.first?.dependents, ["ffmpeg"])
	}
	
	func testSwitchSkipsPackagesWithoutAlternativeOrWithUnsafeName() {
		let plan = PackageSwitch.plan(for: [brew("git", alternative: nil), brew("evil", alternative: "x; rm -rf /")], dependents: [:])
		XCTAssertTrue(plan.toSwitch.isEmpty)
		XCTAssertEqual(plan.withoutAlternative.map(\.name), ["git", "evil"])
	}
}
