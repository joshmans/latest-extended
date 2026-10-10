//
//  AppStoreUpdatesTest.swift
//  LatestTests
//

import XCTest
@testable import Latest

final class AppStoreUpdatesTest: XCTestCase {
	
	private func store(source: App.Source, remote: String = "2.0", ignored: Bool = false) -> AppDataStore {
		let bundle = App.Bundle(version: Version(versionNumber: "1.0", buildNumber: nil), name: "Sample", bundleIdentifier: "test.sample.\(UUID().uuidString)", fileURL: URL(fileURLWithPath: "/Applications/Sample.app"), source: source)
		let update = App.Update(app: bundle, remoteVersion: Version(versionNumber: remote, buildNumber: nil), minimumOSVersion: nil, source: source, date: nil, releaseNotes: nil, updateAction: .external(label: "Store", block: { _ in }))
		let store = AppDataStore()
		_ = store.set(appBundles: [bundle])
		let app = store.set(.success(update), for: bundle)
		if ignored {
			store.setIgnoredState(true, for: app)
			// Setting the state writes to the app's preferences. Remove the throwaway identifier again.
			addTeardownBlock {
				let remaining = (UserDefaults.standard.array(forKey: "IgnoredAppsKey") as? [String] ?? []).filter { $0 != bundle.bundleIdentifier }
				UserDefaults.standard.set(remaining, forKey: "IgnoredAppsKey")
			}
		}
		return store
	}
	
	func testReportsPendingAppStoreUpdate() {
		XCTAssertTrue(store(source: .appStore).hasAppStoreUpdates)
	}
	
	func testIgnoresUpToDateIgnoredAndOtherSources() {
		XCTAssertFalse(store(source: .appStore, remote: "1.0").hasAppStoreUpdates, "Already up to date")
		XCTAssertFalse(store(source: .appStore, ignored: true).hasAppStoreUpdates, "Ignored apps must not trigger the App Store")
		XCTAssertFalse(store(source: .homebrew).hasAppStoreUpdates)
		XCTAssertFalse(store(source: .sparkle).hasAppStoreUpdates)
	}
	
	func testAppStoreAppsStayInTheDefaultList() {
		let store = store(source: .appStore)
		XCTAssertTrue(store.apps.allSatisfy { $0.canStartUpdateFromList })
	}
	
	func testUpdatesPageUsesTheAppStoreScheme() {
		XCTAssertEqual(AppStoreLinks.updatesPage.absoluteString, "macappstore://showUpdatesPage")
	}
}
