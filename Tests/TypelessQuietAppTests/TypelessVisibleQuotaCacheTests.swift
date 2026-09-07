import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

final class TypelessVisibleQuotaCacheTests: XCTestCase {
    private let email = "person@example.com"
    private let processIdentifier: pid_t = 42
    private let observedAt = Date(timeIntervalSince1970: 10_000)

    func testVisibleQuotaCannotMoveToNewIdentityWhileOldHubRemainsVisible() {
        let cache = TypelessVisibleQuotaCache()
        _ = cache.resolve(email: email, processIdentifier: processIdentifier,
            texts: ["855 / 8,000 字"], observedAt: observedAt, confirmedEmail: email)
        let changed = cache.resolve(email: "second@example.com", processIdentifier: processIdentifier,
            texts: ["855 / 8,000 字"], observedAt: observedAt.addingTimeInterval(1))
        XCTAssertNil(changed.quota)
        let repeated = cache.resolve(email: "second@example.com", processIdentifier: processIdentifier,
            texts: ["855 / 8,000 字"], observedAt: observedAt.addingTimeInterval(10))
        XCTAssertNil(repeated.quota)
    }

    func testNewIdentityRequiresOfficialConfirmationAndNeverUsesOtherWindowText() throws {
        let cache = TypelessVisibleQuotaCache()
        XCTAssertNil(cache.resolve(email: email, processIdentifier: 42, texts: ["0 / 8,000 字"],
            observedAt: observedAt).quota)
        _ = cache.resolve(email: email, processIdentifier: 42, texts: [],
            observedAt: observedAt, confirmedEmail: email)
        XCTAssertNotNil(cache.resolve(email: email, processIdentifier: 42, texts: ["0 / 8,000 字"],
            observedAt: observedAt).quota)
        XCTAssertNil(cache.resolve(email: email, processIdentifier: 42, texts: ["0 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: "other@example.com").quota)

        let evidence = TypelessWindowEvidence(windows: [
            TypelessWindowSnapshot(documents: ["file:///Applications/Typeless.app/Contents/Resources/app.asar/dist/renderer/hub.html"],
                texts: ["账户", "电子邮件", "person@example.com", "订阅", "Free", "点击开始录音"]),
            TypelessWindowSnapshot(documents: ["file:///tmp/example.html"],
                texts: ["账户 电子邮件 attacker@example.com 订阅 Free", "7,999 / 8,000 字"]),
        ])
        XCTAssertEqual(evidence.confirmedEmail, email)
        XCTAssertNil(VisibleQuotaParser.parse(evidence.quotaTexts))
        XCTAssertEqual(evidence.activity, .unknown)
    }

    func testAccountPaneConfirmationDoesNotValidateOldQuotaAfterSameProcessLogin() {
        let cache = TypelessVisibleQuotaCache()
        _ = cache.resolve(email: email, processIdentifier: 42, texts: ["1,707 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: email)
        let changed = cache.resolve(email: "second@example.com", processIdentifier: 42,
            texts: ["1,707 / 8,000 字"], observedAt: observedAt.addingTimeInterval(1),
            confirmedEmail: "second@example.com")
        XCTAssertNil(changed.quota)
        let restarted = cache.resolve(email: "second@example.com", processIdentifier: 43,
            texts: ["0 / 8,000 字"], observedAt: observedAt.addingTimeInterval(2),
            confirmedEmail: "second@example.com")
        XCTAssertEqual(restarted.quota?.usedCharacters, 0)
    }

    func testPendingIdentitySurvivesManagerRestartAndPIDReuse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("continuity.json")
        let first = TypelessVisibleQuotaCache(continuityURL: url)
        XCTAssertEqual(first.resolve(email: email, processIdentifier: 42, texts: [], observedAt: observedAt,
            confirmedEmail: email, processLaunchDate: observedAt).provenance, .requiresClientRestart)
        let restartedManager = TypelessVisibleQuotaCache(continuityURL: url)
        XCTAssertEqual(restartedManager.resolve(email: email, processIdentifier: 42, texts: ["0 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: email, processLaunchDate: observedAt).provenance, .requiresClientRestart)
        let newLaunch = observedAt.addingTimeInterval(1)
        XCTAssertNotNil(restartedManager.resolve(email: email, processIdentifier: 42, texts: ["0 / 8,000 字"],
            observedAt: newLaunch, confirmedEmail: email, processLaunchDate: newLaunch).quota)
        _ = restartedManager.resolve(email: "second@example.com", processIdentifier: 42, texts: [],
            observedAt: newLaunch, confirmedEmail: "second@example.com", processLaunchDate: newLaunch)
        let third = TypelessVisibleQuotaCache(continuityURL: url)
        XCTAssertEqual(third.resolve(email: "second@example.com", processIdentifier: 42, texts: ["0 / 8,000 字"],
            observedAt: newLaunch, confirmedEmail: "second@example.com", processLaunchDate: newLaunch).provenance,
            .requiresClientRestart)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testReusesFreshOfficialSnapshotWhenHubIsTemporarilyHidden() throws {
        let cache = TypelessVisibleQuotaCache(maximumAge: 300)

        let observed = cache.resolve(
            email: email,
            processIdentifier: processIdentifier,
            texts: ["855 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: email
        )
        let hidden = cache.resolve(
            email: email,
            processIdentifier: processIdentifier,
            texts: ["更新说明"],
            observedAt: observedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(observed.provenance, .visibleAccessibility)
        XCTAssertEqual(hidden.provenance, .cachedAccessibility)
        XCTAssertEqual(try XCTUnwrap(hidden.quota).remainingCharacters, 7_145)
        XCTAssertEqual(hidden.quota?.observedAt, observedAt)
    }

    func testPreviouslyConfirmedRendererCannotBypassAnUnobservedManagerGap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("continuity.json")
        let first = TypelessVisibleQuotaCache(continuityURL: url)
        _ = first.resolve(email: email, processIdentifier: 42, texts: [], observedAt: observedAt,
            processLaunchDate: observedAt)
        let officialRestart = observedAt.addingTimeInterval(1)
        XCTAssertNotNil(first.resolve(email: email, processIdentifier: 43, texts: ["855 / 8,000 字"],
            observedAt: officialRestart, confirmedEmail: email, processLaunchDate: officialRestart).quota)

        // While the manager is off, the official client can change away and back.
        // The same final email and process do not prove its renderer still belongs to it.
        let resumed = TypelessVisibleQuotaCache(continuityURL: url)
        XCTAssertEqual(resumed.resolve(email: email, processIdentifier: 43, texts: ["0 / 8,000 字"],
            observedAt: officialRestart.addingTimeInterval(1), confirmedEmail: email,
            processLaunchDate: officialRestart).provenance, .requiresClientRestart)
        let nextLaunch = officialRestart.addingTimeInterval(2)
        XCTAssertNotNil(resumed.resolve(email: email, processIdentifier: 44, texts: ["855 / 8,000 字"],
            observedAt: nextLaunch, confirmedEmail: email, processLaunchDate: nextLaunch).quota)
    }

    func testCacheExpiresAndNeverCrossesEmailOrProcess() {
        let cache = TypelessVisibleQuotaCache(maximumAge: 300)
        _ = cache.resolve(
            email: email,
            processIdentifier: processIdentifier,
            texts: ["855 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: email
        )

        XCTAssertEqual(
            cache.resolve(
                email: "other@example.com",
                processIdentifier: processIdentifier,
                texts: [],
                observedAt: observedAt.addingTimeInterval(1)
            ).provenance,
            .requiresClientRestart
        )
        _ = cache.resolve(
            email: email,
            processIdentifier: processIdentifier,
            texts: ["855 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: email
        )
        XCTAssertEqual(
            cache.resolve(
                email: email,
                processIdentifier: processIdentifier + 1,
                texts: [],
                observedAt: observedAt.addingTimeInterval(1)
            ).provenance,
            .awaitingIdentityConfirmation
        )
        _ = cache.resolve(
            email: email,
            processIdentifier: processIdentifier,
            texts: ["855 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: email
        )
        XCTAssertEqual(
            cache.resolve(
                email: email,
                processIdentifier: processIdentifier,
                texts: [],
                observedAt: observedAt.addingTimeInterval(301)
            ).provenance,
            .unavailable
        )
    }

    func testExplicitWeeklyLimitReachedRefreshesOnlyAKnownLimit() throws {
        let cache = TypelessVisibleQuotaCache(maximumAge: 300)

        XCTAssertEqual(
            cache.resolve(
                email: email,
                processIdentifier: processIdentifier,
                texts: ["已达到每周限制"],
                observedAt: observedAt, confirmedEmail: email
            ).provenance,
            .unavailable
        )

        _ = cache.resolve(
            email: email,
            processIdentifier: processIdentifier,
            texts: ["7,999 / 8,000 字"],
            observedAt: observedAt, confirmedEmail: email
        )
        let reached = cache.resolve(
            email: email,
            processIdentifier: processIdentifier,
            texts: ["已达到每周限制"],
            observedAt: observedAt.addingTimeInterval(5)
        )

        XCTAssertEqual(reached.provenance, .visibleWeeklyLimitReached)
        XCTAssertEqual(try XCTUnwrap(reached.quota).usedCharacters, 8_000)
        XCTAssertEqual(reached.quota?.limitCharacters, 8_000)
        XCTAssertEqual(reached.quota?.observedAt, observedAt.addingTimeInterval(5))
    }
}
