import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

private final class MutableSwitchStateReader: TypelessCurrentStateReading {
    var result: TypelessStateReadResult

    init(result: TypelessStateReadResult) {
        self.result = result
    }

    func read() throws -> TypelessStateReadResult { result }
}

private final class SwitchTestSecretStore: AccountSecretStoring, @unchecked Sendable {
    func containsSecret(accountID: UUID) throws -> Bool { false }
    func readSecret(accountID: UUID) throws -> String? { nil }
    func saveSecret(_ secret: String, accountID: UUID) throws {}
    func deleteSecret(accountID: UUID) throws {}
}

@MainActor
private final class FakeLoginOpener: OfficialTypelessLoginOpening {
    let loginURL = OfficialTypelessLoginOpener.defaultLoginURL
    var shouldOpen = true
    var openCount = 0

    func openLogin() -> Bool {
        openCount += 1
        return shouldOpen
    }
}

private final class MemorySwitchAuditStore: SwitchAuditStoring, @unchecked Sendable {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("switch-audit.json")
    var log = SwitchAuditLog()
    var failAppend = false

    func load() throws -> SwitchAuditLog { log }

    func append(_ event: SwitchAuditEvent) throws -> SwitchAuditLog {
        if failAppend { throw SwitchTestError.injected }
        log.events.append(event)
        return log
    }
}

private enum SwitchTestError: Error {
    case injected
}

private final class SwitchTestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor
final class SwitchCoordinatorTests: XCTestCase {
    private let initialDate = Date(timeIntervalSince1970: 30_000)

    func testTargetWithoutQuotaTimeoutDoesNotOpenOriginalLoginAndCanResume() throws {
        let fixture = try makeFixture()
        fixture.coordinator.startSwitch(to: fixture.target.id)
        var target = fixture.makeState(fixture.target, initialDate.addingTimeInterval(1))
        target.quota = nil
        fixture.reader.result = TypelessStateReadResult(state: target,
            storageURL: fixture.reader.result.storageURL, appVersion: "2.5.0", appRunning: true)
        fixture.clock.date = try XCTUnwrap(fixture.coordinator.operation?.verificationDeadline)
        fixture.coordinator.pollOnce()
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(fixture.opener.openCount, 1)
        XCTAssertEqual(fixture.coordinator.operation?.failureCode, .verificationQuotaMissingOrStale)
        XCTAssertEqual(fixture.coordinator.operation?.outcome, .verificationRequired)
        fixture.coordinator.resumeVerification()
        XCTAssertTrue(fixture.coordinator.isBusy)
        XCTAssertEqual(fixture.opener.openCount, 1)
        fixture.clock.date = fixture.clock.date.addingTimeInterval(1)
        fixture.reader.result = fixture.result(account: fixture.target, quotaObservedAt: fixture.clock.date)
        fixture.coordinator.pollOnce()
        XCTAssertEqual(fixture.coordinator.operation?.outcome, .succeeded)

    }

    func testCancelBeforeAnyLoginPreservesOriginalEvenWhenQuotaUnavailable() throws {
        let fixture = try makeFixture()
        fixture.coordinator.startSwitch(to: fixture.target.id)
        var current = fixture.makeState(fixture.current, initialDate)
        current.quota = nil
        fixture.reader.result = TypelessStateReadResult(state: current,
            storageURL: fixture.reader.result.storageURL, appVersion: "2.5.0", appRunning: true)
        fixture.coordinator.cancelAndRestore()
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(fixture.coordinator.operation?.outcome, .cancelled)
        XCTAssertEqual(fixture.opener.openCount, 1)
    }

    func testResumeAuditFailureDoesNotClaimOriginalAccountWasPreserved() throws {
        let fixture = try makeFixture()
        fixture.coordinator.startSwitch(to: fixture.target.id)
        var target = fixture.makeState(fixture.target, initialDate.addingTimeInterval(1))
        target.quota = nil
        fixture.reader.result = TypelessStateReadResult(state: target,
            storageURL: fixture.reader.result.storageURL, appVersion: "2.5.0", appRunning: true)
        fixture.clock.date = try XCTUnwrap(fixture.coordinator.operation?.verificationDeadline)
        fixture.coordinator.pollOnce()
        fixture.audit.failAppend = true

        fixture.coordinator.resumeVerification()

        XCTAssertEqual(fixture.coordinator.operation?.outcome, .verificationRequired)
        XCTAssertEqual(fixture.coordinator.operation?.failureCode, .auditWriteFailed)
        XCTAssertFalse(fixture.coordinator.isBusy)
        XCTAssertEqual(fixture.opener.openCount, 1)
    }

    func testOfficialLoginURLIsFixedHTTPSAndContainsNoCredentials() {
        let value = OfficialTypelessLoginOpener.defaultLoginURL.absoluteString

        XCTAssertEqual(value, "https://www.typeless.com/login?client_platform=macos")
        XCTAssertFalse(value.lowercased().contains("token"))
        XCTAssertFalse(value.lowercased().contains("password"))
        XCTAssertFalse(value.lowercased().contains("email="))
    }

    func testSwitchUIFixtureContainsTwoSecretFreeValidAccounts() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = testsDirectory
            .appendingPathComponent("Fixtures/typeless-switch-qa/accounts.json")

        let directory = try AccountDirectoryStore(fileURL: fileURL).load()
        let serialized = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)

        XCTAssertEqual(directory.accounts.count, 2)
        XCTAssertFalse(directory.accounts.contains(where: \.hasSecret))
        XCTAssertFalse(serialized.lowercased().contains("password"))
        XCTAssertFalse(serialized.lowercased().contains("token"))
    }

    func testStartsOfficialLoginAndSucceedsOnlyAfterFreshTargetObservation() throws {
        let fixture = try makeFixture()

        fixture.coordinator.startSwitch(to: fixture.target.id)

        XCTAssertEqual(fixture.opener.openCount, 1)
        XCTAssertEqual(fixture.coordinator.operation?.phase, .verifying)
        XCTAssertEqual(fixture.audit.log.events.map(\.phase), [
            .preflight, .requestingSwitch, .verifying,
        ])

        fixture.clock.date = initialDate.addingTimeInterval(2)
        fixture.reader.result = fixture.result(
            account: fixture.target,
            quotaObservedAt: initialDate.addingTimeInterval(1)
        )
        fixture.coordinator.pollOnce()

        XCTAssertEqual(fixture.coordinator.operation?.phase, .succeeded)
        XCTAssertEqual(fixture.coordinator.operation?.outcome, .succeeded)
        XCTAssertEqual(fixture.audit.log.events.last?.phase, .succeeded)
    }

    func testTimeoutWithOriginalAccountLeavesItPreserved() throws {
        let fixture = try makeFixture()
        fixture.coordinator.startSwitch(to: fixture.target.id)
        fixture.clock.date = try XCTUnwrap(
            fixture.coordinator.operation?.verificationDeadline
        )
        fixture.reader.result = fixture.result(
            account: fixture.current,
            quotaObservedAt: fixture.clock.date
        )

        fixture.coordinator.pollOnce()

        XCTAssertEqual(fixture.coordinator.operation?.phase, .failed)
        XCTAssertEqual(fixture.coordinator.operation?.outcome, .originalPreserved)
        XCTAssertEqual(fixture.coordinator.operation?.failureCode, .verificationTimedOut)
        XCTAssertEqual(fixture.opener.openCount, 1)
    }

    func testWrongAccountTriggersOfficialRollbackAndVerifiesOriginal() throws {
        let fixture = try makeFixture()
        let unexpected = try AccountProfile(
            displayName: "Unexpected",
            email: "unexpected@example.test"
        )
        fixture.coordinator.startSwitch(to: fixture.target.id)
        fixture.clock.date = try XCTUnwrap(
            fixture.coordinator.operation?.verificationDeadline
        )
        fixture.reader.result = fixture.result(
            account: unexpected,
            quotaObservedAt: fixture.clock.date
        )

        fixture.coordinator.pollOnce()

        XCTAssertEqual(fixture.coordinator.operation?.phase, .restoring)
        XCTAssertEqual(fixture.opener.openCount, 2)
        let rollbackAt = try XCTUnwrap(fixture.coordinator.operation?.rollbackRequestedAt)

        fixture.clock.date = rollbackAt.addingTimeInterval(2)
        fixture.reader.result = fixture.result(
            account: fixture.current,
            quotaObservedAt: rollbackAt.addingTimeInterval(1)
        )
        fixture.coordinator.pollOnce()

        XCTAssertEqual(fixture.coordinator.operation?.phase, .failed)
        XCTAssertEqual(fixture.coordinator.operation?.outcome, .originalRestored)
        XCTAssertEqual(
            fixture.coordinator.operation?.failureCode,
            .verificationObservedDifferentAccount
        )
    }

    func testAuditFailureBlocksBeforeOpeningOfficialLogin() throws {
        let fixture = try makeFixture()
        fixture.audit.failAppend = true

        fixture.coordinator.startSwitch(to: fixture.target.id)

        XCTAssertEqual(fixture.opener.openCount, 0)
        XCTAssertEqual(fixture.coordinator.operation?.phase, .failed)
        XCTAssertEqual(fixture.coordinator.operation?.failureCode, .auditWriteFailed)
    }

    func testOfficialLoginOpenFailureKeepsOriginalAccount() throws {
        let fixture = try makeFixture()
        fixture.opener.shouldOpen = false

        fixture.coordinator.startSwitch(to: fixture.target.id)

        XCTAssertEqual(fixture.opener.openCount, 1)
        XCTAssertEqual(fixture.coordinator.operation?.phase, .failed)
        XCTAssertEqual(fixture.coordinator.operation?.outcome, .originalPreserved)
        XCTAssertEqual(fixture.coordinator.operation?.failureCode, .officialLoginOpenFailed)
    }

    func testAuditStoreIsVersionedPermissionedBoundedAndSecretFree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("switch-audit.json")
        let store = SwitchAuditStore(fileURL: fileURL, maximumEventCount: 2)
        let originalID = UUID()
        let targetID = UUID()
        for phase in [SwitchPhase.preflight, .verifying, .succeeded] {
            _ = try store.append(SwitchAuditEvent(
                transactionID: UUID(),
                originalAccountID: originalID,
                targetAccountID: targetID,
                source: .manual,
                phase: phase,
                occurredAt: initialDate
            ))
        }

        let loaded = try store.load()
        let serialized = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)

        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.events.map(\.phase), [.verifying, .succeeded])
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertFalse(serialized.contains("@"))
        XCTAssertFalse(serialized.lowercased().contains("password"))
        XCTAssertFalse(serialized.lowercased().contains("cookie"))
    }

    func testStartupClosesInterruptedAuditWithoutResumingSwitch() throws {
        let fixture = try makeFixture()
        fixture.audit.log.events = [SwitchAuditEvent(
            transactionID: UUID(),
            originalAccountID: fixture.current.id,
            targetAccountID: fixture.target.id,
            source: .manual,
            phase: .verifying,
            occurredAt: initialDate
        )]

        let coordinator = SwitchCoordinator(
            accountManager: fixture.manager,
            loginOpener: fixture.opener,
            auditStore: fixture.audit,
            now: { fixture.clock.date },
            backgroundVerificationEnabled: false
        )

        XCTAssertEqual(coordinator.auditEvents.last?.phase, .failed)
        XCTAssertEqual(coordinator.auditEvents.last?.failureCode, .interrupted)
        XCTAssertEqual(coordinator.auditEvents.last?.outcome, .recoveryRequired)
        XCTAssertEqual(coordinator.operation?.outcome, .recoveryRequired)
        XCTAssertTrue(coordinator.canRecoverTerminalOperation)
        XCTAssertEqual(fixture.opener.openCount, 0)

        coordinator.recoverTerminalOperation()

        XCTAssertEqual(coordinator.operation?.phase, .restoring)
        XCTAssertEqual(fixture.opener.openCount, 1)
    }

    func testStartupDoesNotMarkCompletedPreflightFailureAsInterrupted() throws {
        let fixture = try makeFixture()
        fixture.audit.log.events = [SwitchAuditEvent(
            transactionID: UUID(),
            originalAccountID: fixture.current.id,
            targetAccountID: fixture.target.id,
            source: .manual,
            phase: .preflight,
            occurredAt: initialDate,
            outcome: .originalPreserved,
            failureCode: .activityUnknown
        )]

        let coordinator = SwitchCoordinator(
            accountManager: fixture.manager,
            loginOpener: fixture.opener,
            auditStore: fixture.audit,
            now: { fixture.clock.date },
            backgroundVerificationEnabled: false
        )

        XCTAssertEqual(coordinator.auditEvents.count, 1)
        XCTAssertEqual(coordinator.auditEvents.last?.failureCode, .activityUnknown)
    }

    private func makeFixture() throws -> Fixture {
        let current = try AccountProfile(
            displayName: "Current",
            email: "current@example.test"
        )
        let target = try AccountProfile(
            displayName: "Target",
            email: "target@example.test"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directoryStore = AccountDirectoryStore(
            fileURL: root.appendingPathComponent("accounts.json")
        )
        try directoryStore.save(try AccountDirectory(accounts: [current, target]))
        let clock = SwitchTestClock(initialDate)
        let state = state(
            account: current,
            quotaObservedAt: initialDate.addingTimeInterval(-1)
        )
        let initialResult = TypelessStateReadResult(
            state: state,
            storageURL: root.appendingPathComponent("app-storage.json"),
            appVersion: "2.4.0",
            appRunning: true
        )
        let reader = MutableSwitchStateReader(result: initialResult)
        let manager = AccountManager(
            directoryStore: directoryStore,
            secretStore: SwitchTestSecretStore(),
            stateReader: reader
        )
        let opener = FakeLoginOpener()
        let audit = MemorySwitchAuditStore()
        let coordinator = SwitchCoordinator(
            accountManager: manager,
            loginOpener: opener,
            auditStore: audit,
            now: { clock.date },
            backgroundVerificationEnabled: false
        )
        return Fixture(
            current: current,
            target: target,
            manager: manager,
            reader: reader,
            opener: opener,
            audit: audit,
            clock: clock,
            coordinator: coordinator,
            makeState: state(account:quotaObservedAt:)
        )
    }

    private func state(
        account: AccountProfile,
        quotaObservedAt: Date
    ) -> CurrentTypelessState {
        CurrentTypelessState(
            email: account.email,
            displayName: account.displayName,
            planName: "Free",
            quota: QuotaSnapshot(
                usedCharacters: 1_000,
                limitCharacters: 8_000,
                observedAt: quotaObservedAt,
                source: .typelessAccessibility
            ),
            observedAt: quotaObservedAt,
            sourceModifiedAt: quotaObservedAt,
            activity: .idle
        )
    }

    private struct Fixture {
        let current: AccountProfile
        let target: AccountProfile
        let manager: AccountManager
        let reader: MutableSwitchStateReader
        let opener: FakeLoginOpener
        let audit: MemorySwitchAuditStore
        let clock: SwitchTestClock
        let coordinator: SwitchCoordinator
        let makeState: (AccountProfile, Date) -> CurrentTypelessState

        func result(account: AccountProfile, quotaObservedAt: Date) -> TypelessStateReadResult {
            TypelessStateReadResult(
                state: makeState(account, quotaObservedAt),
                storageURL: reader.result.storageURL,
                appVersion: "2.4.0",
                appRunning: true
            )
        }
    }
}
