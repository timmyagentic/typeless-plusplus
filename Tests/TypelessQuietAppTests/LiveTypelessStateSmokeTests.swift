import AppKit
import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

final class LiveTypelessStateSmokeTests: XCTestCase {
    func testReadsCurrentTypeless250IdentityWithoutPrintingValues() throws {
        try requireLiveQA()
        let result = try TypelessCurrentStateReader(visibleQuotaCache: TypelessVisibleQuotaCache()).read()

        XCTAssertEqual(result.appVersion, "2.5.0")
        XCTAssertTrue(result.appRunning)
        XCTAssertNotNil(result.state.email)
    }

    func testReadsFreshVisibleQuotaWhenCurrentInterfaceExposesIt() throws {
        try requireLiveQA()
        let result = try TypelessCurrentStateReader(visibleQuotaCache: TypelessVisibleQuotaCache()).read()
        guard let quota = result.state.quota else {
            throw XCTSkip("Current Typeless interface does not expose a readable quota")
        }

        XCTAssertEqual(quota.source, .typelessAccessibility)
        XCTAssertTrue(quota.isFresh())
    }

    func testReadsActivityWhenCurrentInterfaceExposesRecordingControl() throws {
        try requireLiveQA()
        let result = try TypelessCurrentStateReader(visibleQuotaCache: TypelessVisibleQuotaCache()).read()
        guard result.state.activity != .unknown else {
            throw XCTSkip("Current Typeless interface does not expose recognized activity controls")
        }

        XCTAssertTrue([
            TypelessActivityState.idle,
            .recording,
            .processing,
        ].contains(result.state.activity))
    }

    func testInspectsOfficialWindowCapabilitiesWithoutPrivateValues() throws {
        try requireLiveQA()
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: TargetPromptMatcher.targetBundleIdentifier).first)
        let windows = TypelessCurrentStateReader(visibleQuotaCache: TypelessVisibleQuotaCache()).accessibilityWindows(processIdentifier: app.processIdentifier)
        for window in windows {
            let accountFields = window.texts.filter {
                ["账户", "电子邮件", "订阅", "Account", "Email", "Subscription"].contains($0)
                    || AccountProfile.normalizedEmail($0) != nil
            }.map { AccountProfile.normalizedEmail($0) == nil ? $0 : "EMAIL_REDACTED" }
            print("Official window capability: hub=\(window.containsDocument("hub.html")), floating=\(window.containsDocument("floating-bar.html")), textCount=\(window.texts.count), accountFields=\(accountFields)")
        }
        XCTAssertFalse(windows.isEmpty)
        let evidence = TypelessWindowEvidence(windows: windows)
        print("Official identity confirmation available: \(evidence.confirmedEmail != nil)")
    }

    private func requireLiveQA() throws {
        guard ProcessInfo.processInfo.environment[
            "TYPELESS_PLUSPLUS_RUN_LIVE_READ_QA"
        ] == "true" else {
            throw XCTSkip("Set TYPELESS_PLUSPLUS_RUN_LIVE_READ_QA=true for local live QA")
        }
    }
}
