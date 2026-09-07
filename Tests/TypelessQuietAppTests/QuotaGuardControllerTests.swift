import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

private final class GuardMutableReader: TypelessCurrentStateReading {
    var result: TypelessStateReadResult
    var onRead: (() -> Void)?
    init(result: TypelessStateReadResult) { self.result = result }
    func read() throws -> TypelessStateReadResult {
        onRead?()
        return result
    }
}

private final class GuardSecretStore: AccountSecretStoring, @unchecked Sendable {
    func containsSecret(accountID: UUID) throws -> Bool { false }
    func readSecret(accountID: UUID) throws -> String? { nil }
    func saveSecret(_ secret: String, accountID: UUID) throws {}
    func deleteSecret(accountID: UUID) throws {}
}

@MainActor
private final class GuardLoginOpener: OfficialTypelessLoginOpening {
    let loginURL = OfficialTypelessLoginOpener.defaultLoginURL
    var shouldOpen = true
    var openCount = 0
    func openLogin() -> Bool {
        openCount += 1
        return shouldOpen
    }
}

private final class GuardAuditStore: SwitchAuditStoring, @unchecked Sendable {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("audit.json")
    var log = SwitchAuditLog()
    func load() throws -> SwitchAuditLog { log }
    func append(_ event: SwitchAuditEvent) throws -> SwitchAuditLog {
        log.events.append(event)
        return log
    }
}

private final class MemoryQuotaGuardStore: QuotaGuardStoring, @unchecked Sendable {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("quota-guard.json")
    var document: QuotaGuardDocument
    var failNextSave = false

    init(document: QuotaGuardDocument) {
        self.document = document
    }

    func load() throws -> QuotaGuardDocument { document }

    func save(_ document: QuotaGuardDocument) throws {
        if failNextSave {
            failNextSave = false
            throw GuardTestError.injected
        }
        self.document = document
    }
}

private enum GuardTestError: Error {
    case injected
}

private final class GuardClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor
final class QuotaGuardControllerTests: XCTestCase {
    private let initialDate = Date(timeIntervalSince1970: 50_000)

    func testNewlyReadQuotaIsEvaluatedAfterObservationCompletes() throws {
        let fixture = try makeFixture()
        let completedAt = initialDate.addingTimeInterval(0.1)
        var state = makeState(account: fixture.current, quotaObservedAt: completedAt)
        state.activity = .unknown
        fixture.reader.result = TypelessStateReadResult(state: state,
            storageURL: fixture.reader.result.storageURL, appVersion: "2.5.0", appRunning: true)
        let clock = fixture.clock
        fixture.reader.onRead = { clock.date = completedAt }

        fixture.guardController.evaluateNow()

        XCTAssertEqual(fixture.guardController.lastCheckedAt, completedAt)
        XCTAssertEqual(fixture.guardController.lastDecision, .needsManualVerification(fixture.target.id))
        XCTAssertEqual(fixture.opener.openCount, 0)
    }

    func testRecommendationDoesNotOpenLoginAndSnoozeDoesNotCountAsFailure() throws {
        let fixture = try makeFixture()
        var state = fixture.reader.result.state
        state.activity = .unknown
        fixture.reader.result = TypelessStateReadResult(state: state,
            storageURL: fixture.reader.result.storageURL, appVersion: "2.5.0", appRunning: true)
        fixture.guardController.evaluateNow()
        XCTAssertEqual(fixture.guardController.recommendedAccountID, fixture.target.id)
        XCTAssertEqual(fixture.opener.openCount, 0)
        fixture.guardController.snoozeRecommendation()
        fixture.guardController.evaluateNow()
        XCTAssertEqual(fixture.guardController.lastDecision, .noAction(.cooldown))
        XCTAssertEqual(fixture.guardController.runtime.consecutiveFailures, 0)
        XCTAssertEqual(fixture.opener.openCount, 0)
    }

    func testRecommendationClickRechecksRecordingAndNeverOpensWhileBusy() throws {
        let fixture = try makeFixture()
        var state = fixture.reader.result.state
        state.activity = .unknown
        fixture.reader.result = TypelessStateReadResult(state: state,
            storageURL: fixture.reader.result.storageURL, appVersion: "2.5.0", appRunning: true)
        fixture.guardController.evaluateNow()
        state.activity = .recording
        fixture.reader.result = TypelessStateReadResult(state: state,
            storageURL: fixture.reader.result.storageURL, appVersion: "2.5.0", appRunning: true)
        fixture.guardController.startRecommendedSwitch()
        XCTAssertEqual(fixture.guardController.lastDecision, .noAction(.activityRecording))
        XCTAssertEqual(fixture.opener.openCount, 0)
    }

    func testStoreDefaultsVersionedRoundTripsAndUsesPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("quota-guard.json")
        let store = QuotaGuardStore(fileURL: fileURL)

        XCTAssertFalse(try store.load().configuration.isEnabled)

        let accountID = UUID()
        let document = QuotaGuardDocument(
            configuration: QuotaGuardConfiguration(
                isEnabled: true,
                thresholdCharacters: 700,
                accountPool: [accountID, UUID()],
                cooldownMinutes: 45
            ),
            runtime: QuotaGuardRuntime(
                lastAttemptAt: initialDate,
                lastTargetAccountID: accountID,
                consecutiveFailures: 2
            )
        )
        try store.save(document)

        XCTAssertEqual(try store.load(), document)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        let serialized = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(serialized.lowercased().contains("password"))
        XCTAssertFalse(serialized.lowercased().contains("token"))
        XCTAssertFalse(serialized.lowercased().contains("cookie"))
    }

    func testStoreRejectsUnsupportedSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("quota-guard.json")
        let store = QuotaGuardStore(fileURL: fileURL)
        try store.save(QuotaGuardDocument(schemaVersion: 2))

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? QuotaGuardStoreError, .invalidSchema)
        }
    }

    func testGuardUIFixtureIsEnabledAndSecretFree() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = testsDirectory
            .appendingPathComponent("Fixtures/typeless-guard-qa/quota-guard.json")
        let document = try QuotaGuardStore(fileURL: fileURL).load()
        let serialized = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)

        XCTAssertTrue(document.configuration.isEnabled)
        XCTAssertEqual(document.configuration.accountPool.count, 2)
        XCTAssertFalse(serialized.lowercased().contains("password"))
        XCTAssertFalse(serialized.lowercased().contains("token"))
        XCTAssertFalse(serialized.lowercased().contains("cookie"))
    }

    func testEvaluateTriggersP2AtMostOnceWhileSwitchIsBusy() throws {
        let fixture = try makeFixture()

        fixture.guardController.evaluateNow()
        fixture.guardController.evaluateNow()

        XCTAssertEqual(fixture.opener.openCount, 1)
        XCTAssertEqual(fixture.switchCoordinator.operation?.source, .quotaGuard)
        XCTAssertEqual(fixture.switchCoordinator.operation?.targetAccountID, fixture.target.id)
        XCTAssertEqual(fixture.guardController.lastDecision, .noAction(.switchInProgress))
        XCTAssertEqual(fixture.guardController.runtime.lastTargetAccountID, fixture.target.id)
        XCTAssertEqual(
            fixture.guardController.runtime.activeTransactionID,
            fixture.switchCoordinator.operation?.id
        )
    }

    func testSuccessfulSwitchClearsFailuresAndPersistsSuccess() throws {
        let fixture = try makeFixture(consecutiveFailures: 2)
        fixture.guardController.evaluateNow()
        fixture.clock.date = initialDate.addingTimeInterval(2)
        fixture.reader.result = fixture.result(
            account: fixture.target,
            quotaObservedAt: initialDate.addingTimeInterval(1)
        )

        fixture.switchCoordinator.pollOnce()
        fixture.guardController.reconcileSwitchOutcome()

        XCTAssertEqual(fixture.guardController.lastSwitchOutcome, .succeeded)
        XCTAssertEqual(fixture.guardController.runtime.consecutiveFailures, 0)
        XCTAssertEqual(fixture.guardController.runtime.lastSuccessAt, fixture.clock.date)
        XCTAssertNil(fixture.guardController.runtime.activeTransactionID)
    }

    func testImmediateP2FailureIncrementsBackoff() throws {
        let fixture = try makeFixture()
        fixture.opener.shouldOpen = false

        fixture.guardController.evaluateNow()

        XCTAssertEqual(fixture.switchCoordinator.operation?.outcome, .originalPreserved)
        XCTAssertEqual(fixture.guardController.runtime.consecutiveFailures, 1)
        XCTAssertNil(fixture.guardController.runtime.activeTransactionID)
    }

    func testStorageFailureBeforeAttemptPreventsSwitch() throws {
        let fixture = try makeFixture()
        fixture.guardStore.failNextSave = true

        fixture.guardController.evaluateNow()

        XCTAssertEqual(fixture.opener.openCount, 0)
        XCTAssertNotNil(fixture.guardController.storageError)
        XCTAssertFalse(fixture.guardController.configuration.isEnabled)

        try fixture.guardController.setThreshold(900)
        XCTAssertNil(fixture.guardController.storageError)
        XCTAssertEqual(fixture.guardController.configuration.thresholdCharacters, 900)
    }

    func testEnablingRequiresStructurallyValidPool() throws {
        let fixture = try makeFixture(isEnabled: false)
        try fixture.guardController.setAccountPool([fixture.current.id])

        XCTAssertThrowsError(try fixture.guardController.setEnabled(true)) {
            XCTAssertEqual($0 as? QuotaGuardControllerError, .invalidPool)
        }
        XCTAssertNotNil(fixture.guardController.configurationError)
        try fixture.guardController.setAccountPool([fixture.current.id, fixture.target.id])
        try fixture.guardController.setEnabled(true)
        XCTAssertTrue(fixture.guardController.configuration.isEnabled)
        XCTAssertNil(fixture.guardController.configurationError)
    }

    func testPersistedCooldownSurvivesControllerRecreation() throws {
        let lastAttempt = initialDate.addingTimeInterval(-60)
        let fixture = try makeFixture(lastAttemptAt: lastAttempt)

        fixture.guardController.evaluateNow()

        XCTAssertEqual(fixture.guardController.lastDecision, .noAction(.cooldown))
        XCTAssertEqual(fixture.opener.openCount, 0)
        XCTAssertEqual(
            fixture.guardController.nextEligibleAt,
            lastAttempt.addingTimeInterval(1_800)
        )
    }

    func testEnabledControllerCreatesTimerOnlyWhenRequested() throws {
        let fixture = try makeFixture(timerEnabled: true)
        XCTAssertTrue(fixture.guardController.isMonitoring)

        try fixture.guardController.setEnabled(false)
        XCTAssertFalse(fixture.guardController.isMonitoring)
    }

    private func makeFixture(
        isEnabled: Bool = true,
        consecutiveFailures: Int = 0,
        lastAttemptAt: Date? = nil,
        timerEnabled: Bool = false
    ) throws -> Fixture {
        var current = try AccountProfile(
            displayName: "Current",
            email: "current@example.test"
        )
        var target = try AccountProfile(
            displayName: "Target",
            email: "target@example.test"
        )
        current.quota = quota(remaining: 100, observedAt: initialDate.addingTimeInterval(-1))
        target.quota = quota(remaining: 3_000, observedAt: initialDate.addingTimeInterval(-1))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directoryStore = AccountDirectoryStore(
            fileURL: root.appendingPathComponent("accounts.json")
        )
        try directoryStore.save(try AccountDirectory(accounts: [current, target]))
        let state = makeState(
            account: current,
            quotaObservedAt: initialDate.addingTimeInterval(-1)
        )
        let result = TypelessStateReadResult(
            state: state,
            storageURL: root.appendingPathComponent("app-storage.json"),
            appVersion: "2.4.0",
            appRunning: true
        )
        let reader = GuardMutableReader(result: result)
        let manager = AccountManager(
            directoryStore: directoryStore,
            secretStore: GuardSecretStore(),
            stateReader: reader
        )
        let opener = GuardLoginOpener()
        let clock = GuardClock(initialDate)
        let switchCoordinator = SwitchCoordinator(
            accountManager: manager,
            loginOpener: opener,
            auditStore: GuardAuditStore(),
            now: { clock.date },
            backgroundVerificationEnabled: false
        )
        let guardDocument = QuotaGuardDocument(
            configuration: QuotaGuardConfiguration(
                isEnabled: isEnabled,
                thresholdCharacters: 500,
                accountPool: [current.id, target.id],
                cooldownMinutes: 30
            ),
            runtime: QuotaGuardRuntime(
                lastAttemptAt: lastAttemptAt,
                consecutiveFailures: consecutiveFailures
            )
        )
        let guardStore = MemoryQuotaGuardStore(document: guardDocument)
        let guardController = QuotaGuardController(
            accountManager: manager,
            switchCoordinator: switchCoordinator,
            store: guardStore,
            now: { clock.date },
            monitoringInterval: 10,
            timerEnabled: timerEnabled
        )
        return Fixture(
            current: current,
            target: target,
            manager: manager,
            reader: reader,
            opener: opener,
            switchCoordinator: switchCoordinator,
            guardStore: guardStore,
            guardController: guardController,
            clock: clock,
            makeState: makeState(account:quotaObservedAt:)
        )
    }

    private func quota(remaining: Int, observedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            usedCharacters: 8_000 - remaining,
            limitCharacters: 8_000,
            observedAt: observedAt,
            source: .typelessAccessibility
        )
    }

    private func makeState(
        account: AccountProfile,
        quotaObservedAt: Date
    ) -> CurrentTypelessState {
        CurrentTypelessState(
            email: account.email,
            displayName: account.displayName,
            planName: "Free",
            quota: quota(remaining: account.email == "current@example.test" ? 100 : 3_000, observedAt: quotaObservedAt),
            observedAt: quotaObservedAt,
            sourceModifiedAt: quotaObservedAt,
            activity: .idle
        )
    }

    private struct Fixture {
        let current: AccountProfile
        let target: AccountProfile
        let manager: AccountManager
        let reader: GuardMutableReader
        let opener: GuardLoginOpener
        let switchCoordinator: SwitchCoordinator
        let guardStore: MemoryQuotaGuardStore
        let guardController: QuotaGuardController
        let clock: GuardClock
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
