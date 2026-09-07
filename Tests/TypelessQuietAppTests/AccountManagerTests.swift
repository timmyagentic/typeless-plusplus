import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

private final class FakeSecretStore: AccountSecretStoring, @unchecked Sendable {
    var values: [UUID: String] = [:]
    var failNextRead = false
    var failNextSave = false
    var failNextDelete = false

    func containsSecret(accountID: UUID) throws -> Bool {
        values[accountID] != nil
    }

    func readSecret(accountID: UUID) throws -> String? {
        if failNextRead {
            failNextRead = false
            throw TestFailure.injected
        }
        return values[accountID]
    }

    func saveSecret(_ secret: String, accountID: UUID) throws {
        if failNextSave {
            failNextSave = false
            throw TestFailure.injected
        }
        values[accountID] = secret
    }

    func deleteSecret(accountID: UUID) throws {
        if failNextDelete {
            failNextDelete = false
            throw TestFailure.injected
        }
        values.removeValue(forKey: accountID)
    }
}

private enum TestFailure: Error {
    case injected
}

private final class FakeDirectoryStore: AccountDirectoryStoring, @unchecked Sendable {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("accounts.json")
    var stored = try! AccountDirectory()
    var failNextSave = false

    func load() throws -> AccountDirectory { stored }

    func save(_ directory: AccountDirectory) throws {
        if failNextSave {
            failNextSave = false
            throw TestFailure.injected
        }
        stored = directory
    }
}

private struct StubStateReader: TypelessCurrentStateReading {
    let result: TypelessStateReadResult

    func read() throws -> TypelessStateReadResult { result }
}

private final class MutableAccountStateReader: TypelessCurrentStateReading, @unchecked Sendable {
    var result: TypelessStateReadResult

    init(result: TypelessStateReadResult) { self.result = result }
    func read() throws -> TypelessStateReadResult { result }
}

@MainActor
private final class FakeTypelessClientController: TypelessClientControlling {
    var restartCount = 0
    func open() -> Bool { true }
    func restart(completion: @escaping (Result<Void, Error>) -> Void) {
        restartCount += 1
        completion(.success(()))
    }
}

@MainActor
final class AccountManagerTests: XCTestCase {
    func testRestartGuidanceDoesNotSurviveAnotherIdentityOrConfirmedQuota() {
        for confirmsQuota in [false, true] {
            let initial = makeReadResult()
            var pendingState = initial.state
            pendingState.quota = nil
            let reader = MutableAccountStateReader(result: TypelessStateReadResult(
                state: pendingState, storageURL: initial.storageURL,
                appVersion: "2.5.0", appRunning: true,
                quotaProvenance: .requiresClientRestart
            ))
            let manager = AccountManager(directoryStore: FakeDirectoryStore(),
                secretStore: FakeSecretStore(), stateReader: reader,
                clientController: FakeTypelessClientController())
            manager.restartTypeless()
            XCTAssertNotNil(manager.clientControlMessage)
            manager.refresh()
            XCTAssertNotNil(manager.clientControlMessage)

            let resolvedState = CurrentTypelessState(
                email: confirmsQuota ? pendingState.email : "another@example.com",
                displayName: nil, planName: "Free",
                quota: confirmsQuota ? QuotaSnapshot(usedCharacters: 100, limitCharacters: 8_000,
                    observedAt: Date(), source: .typelessAccessibility) : nil,
                observedAt: Date(), sourceModifiedAt: Date()
            )
            reader.result = TypelessStateReadResult(state: resolvedState,
                storageURL: initial.storageURL, appVersion: "2.5.0", appRunning: true,
                quotaProvenance: confirmsQuota ? .visibleAccessibility : .requiresClientRestart)
            manager.refresh()

            XCTAssertNil(manager.clientControlMessage,
                "Previous restart guidance must not reappear for another login or after quota confirmation")
        }
    }

    func testExplicitRestartProtectsRecordingAndProcessingButDoesNotInventIdle() {
        for activity in [TypelessActivityState.recording, .processing, .unknown] {
            let original = makeReadResult()
            var state = original.state
            state.activity = activity
            let result = TypelessStateReadResult(state: state, storageURL: original.storageURL,
                appVersion: "2.5.0", appRunning: true)
            let controller = FakeTypelessClientController()
            let manager = AccountManager(directoryStore: FakeDirectoryStore(),
                secretStore: FakeSecretStore(), stateReader: StubStateReader(result: result),
                clientController: controller)

            manager.restartTypeless()

            XCTAssertEqual(controller.restartCount, activity == .unknown ? 1 : 0)
            XCTAssertEqual(manager.currentState?.activity, activity)
            XCTAssertFalse(manager.isRestartingTypeless)
        }
    }

    func testManualEntryRemainsUnverifiedAndEmailEditClearsQuota() throws {
        let fixture = try makeFixture()
        try fixture.manager.addAccount(displayName: "New", email: "new@example.com", note: "", secret: "")
        let newAccount = try XCTUnwrap(fixture.manager.accounts.first { $0.email == "new@example.com" })
        XCTAssertEqual(newAccount.status, .unknown)
        try fixture.manager.setPaused(true, accountID: newAccount.id)
        try fixture.manager.setPaused(false, accountID: newAccount.id)
        XCTAssertEqual(fixture.manager.accounts.first { $0.id == newAccount.id }?.status, .unknown)

        try fixture.manager.addCurrentAccount()
        let current = try XCTUnwrap(fixture.manager.accounts.first { $0.email == "person@example.com" })
        try fixture.manager.updateAccount(id: current.id, displayName: "Edited", email: "edited@example.com",
            note: "", status: .available, autoSwitchEligible: true, newSecret: nil, clearSecret: false)
        let edited = try XCTUnwrap(fixture.manager.accounts.first { $0.id == current.id })
        XCTAssertNil(edited.quota)
        XCTAssertEqual(edited.status, .unknown)
        XCTAssertFalse(edited.autoSwitchEligible)
    }

    func testAddsAccountAndKeepsSecretOutOfJSON() throws {
        let fixture = try makeFixture()
        let manager = fixture.manager

        try manager.addAccount(
            displayName: "Personal",
            email: "person@example.com",
            note: "Primary",
            secret: "SECRET-PASSWORD"
        )

        let account = try XCTUnwrap(manager.accounts.first)
        let serialized = String(decoding: try Data(contentsOf: fixture.fileURL), as: UTF8.self)
        XCTAssertTrue(account.hasSecret)
        XCTAssertEqual(fixture.secretStore.values[account.id], "SECRET-PASSWORD")
        XCTAssertFalse(serialized.contains("SECRET-PASSWORD"))
        XCTAssertFalse(serialized.lowercased().contains("password"))
    }

    func testPreservesSignificantWhitespaceInSecret() throws {
        let fixture = try makeFixture()

        try fixture.manager.addAccount(
            displayName: "Personal",
            email: "space@example.com",
            note: "",
            secret: " leading-and-trailing "
        )

        let account = try XCTUnwrap(fixture.manager.accounts.first)
        XCTAssertEqual(fixture.secretStore.values[account.id], " leading-and-trailing ")
    }

    func testRefreshUpdatesManagedAccountQuota() throws {
        let fixture = try makeFixture()
        try fixture.manager.addAccount(
            displayName: "Personal",
            email: "person@example.com",
            note: "",
            secret: ""
        )

        fixture.manager.refresh()

        XCTAssertEqual(fixture.manager.accounts.first?.quota, fixture.result.state.quota)
        XCTAssertTrue(fixture.manager.currentAccountIsManaged)
    }

    func testRefreshWithoutQuotaKeepsLastManagedSnapshot() throws {
        let directoryStore = FakeDirectoryStore()
        let secretStore = FakeSecretStore()
        let previousQuota = QuotaSnapshot(
            usedCharacters: 1_000,
            limitCharacters: 8_000,
            observedAt: Date(timeIntervalSince1970: 1_000),
            source: .typelessAccessibility
        )
        let account = try AccountProfile(
            displayName: "Person",
            email: "person@example.com",
            quota: previousQuota
        )
        directoryStore.stored = try AccountDirectory(accounts: [account])
        let result = TypelessStateReadResult(
            state: CurrentTypelessState(
                email: account.email,
                displayName: account.displayName,
                planName: "Free",
                quota: nil,
                observedAt: Date(),
                sourceModifiedAt: Date()
            ),
            storageURL: directoryStore.fileURL,
            appVersion: "2.4.0",
            appRunning: true
        )

        let manager = AccountManager(
            directoryStore: directoryStore,
            secretStore: secretStore,
            stateReader: StubStateReader(result: result)
        )

        XCTAssertNil(manager.currentState?.quota)
        XCTAssertEqual(manager.accounts.first?.quota, previousQuota)
    }

    func testAddsCurrentAccountWithoutSecret() throws {
        let fixture = try makeFixture()

        try fixture.manager.addCurrentAccount()

        let account = try XCTUnwrap(fixture.manager.accounts.first)
        XCTAssertEqual(account.email, "person@example.com")
        XCTAssertFalse(account.hasSecret)
        XCTAssertEqual(account.quota, fixture.result.state.quota)
    }

    func testRemoveAccountDeletesKeychainSecret() throws {
        let fixture = try makeFixture()
        try fixture.manager.addAccount(
            displayName: "Personal",
            email: "person@example.com",
            note: "",
            secret: "SECRET"
        )
        let account = try XCTUnwrap(fixture.manager.accounts.first)

        try fixture.manager.removeAccount(id: account.id)

        XCTAssertTrue(fixture.manager.accounts.isEmpty)
        XCTAssertNil(fixture.secretStore.values[account.id])
    }

    func testDuplicateUpdateDoesNotTouchKeychainOrMetadata() throws {
        let fixture = try makeFixture()
        try fixture.manager.addAccount(
            displayName: "One",
            email: "one@example.com",
            note: "",
            secret: "ORIGINAL"
        )
        try fixture.manager.addAccount(
            displayName: "Two",
            email: "two@example.com",
            note: "",
            secret: ""
        )
        let first = try XCTUnwrap(fixture.manager.accounts.first { $0.email == "one@example.com" })

        XCTAssertThrowsError(try fixture.manager.updateAccount(
            id: first.id,
            displayName: "Changed",
            email: "TWO@example.com",
            note: "",
            status: .available,
            autoSwitchEligible: false,
            newSecret: "REPLACEMENT",
            clearSecret: false
        ))

        XCTAssertEqual(fixture.secretStore.values[first.id], "ORIGINAL")
        XCTAssertEqual(fixture.manager.accounts.first { $0.id == first.id }?.displayName, "One")
    }

    func testFailedMetadataCommitRestoresPreviousKeychainSecret() throws {
        let directoryStore = FakeDirectoryStore()
        let secretStore = FakeSecretStore()
        let result = makeReadResult()
        let manager = AccountManager(
            directoryStore: directoryStore,
            secretStore: secretStore,
            stateReader: StubStateReader(result: result)
        )
        try manager.addAccount(
            displayName: "Person",
            email: "person@example.com",
            note: "Before",
            secret: "ORIGINAL"
        )
        let account = try XCTUnwrap(manager.accounts.first)
        directoryStore.failNextSave = true

        XCTAssertThrowsError(try manager.updateAccount(
            id: account.id,
            displayName: "Changed",
            email: account.email,
            note: "After",
            status: .available,
            autoSwitchEligible: false,
            newSecret: "REPLACEMENT",
            clearSecret: false
        ))

        XCTAssertEqual(secretStore.values[account.id], "ORIGINAL")
        XCTAssertEqual(manager.accounts.first?.displayName, "Person")
        XCTAssertEqual(directoryStore.stored.accounts.first?.note, "Before")
    }

    func testFailedDeleteCommitRestoresKeychainAndAccount() throws {
        let directoryStore = FakeDirectoryStore()
        let secretStore = FakeSecretStore()
        let manager = AccountManager(
            directoryStore: directoryStore,
            secretStore: secretStore,
            stateReader: StubStateReader(result: makeReadResult())
        )
        try manager.addAccount(
            displayName: "Person",
            email: "person@example.com",
            note: "",
            secret: "ORIGINAL"
        )
        let account = try XCTUnwrap(manager.accounts.first)
        directoryStore.failNextSave = true

        XCTAssertThrowsError(try manager.removeAccount(id: account.id))

        XCTAssertEqual(secretStore.values[account.id], "ORIGINAL")
        XCTAssertEqual(manager.accounts.first?.id, account.id)
        XCTAssertEqual(directoryStore.stored.accounts.first?.id, account.id)
    }

    func testDiagnosticsReportQuotaSourceAndFreshness() {
        let directoryStore = FakeDirectoryStore()
        let quota = QuotaSnapshot(
            usedCharacters: 100,
            limitCharacters: 8_000,
            observedAt: Date(),
            source: .typelessLocalStorage
        )
        let result = TypelessStateReadResult(
            state: CurrentTypelessState(
                email: "person@example.com",
                displayName: "Person",
                planName: "Free",
                quota: quota,
                observedAt: Date(),
                sourceModifiedAt: Date()
            ),
            storageURL: directoryStore.fileURL,
            appVersion: "2.4.0",
            appRunning: true
        )

        let manager = AccountManager(
            directoryStore: directoryStore,
            secretStore: FakeSecretStore(),
            stateReader: StubStateReader(result: result)
        )

        let diagnostic = manager.diagnostics.first { $0.id == "quota" }
        XCTAssertEqual(diagnostic?.level, .success)
        XCTAssertTrue(diagnostic?.detail.contains("只读本地状态") == true)
        XCTAssertTrue(diagnostic?.detail.contains("快照新鲜") == true)
    }

    func testDiagnosticsDistinguishTemporarilyCachedOfficialQuota() {
        let directoryStore = FakeDirectoryStore()
        let quota = QuotaSnapshot(
            usedCharacters: 855,
            limitCharacters: 8_000,
            observedAt: Date(),
            source: .typelessAccessibility
        )
        let result = TypelessStateReadResult(
            state: CurrentTypelessState(
                email: "person@example.com",
                displayName: "Person",
                planName: "Free",
                quota: quota,
                observedAt: Date(),
                sourceModifiedAt: Date()
            ),
            storageURL: directoryStore.fileURL,
            appVersion: "2.5.0",
            appRunning: true,
            quotaProvenance: .cachedAccessibility
        )

        let manager = AccountManager(
            directoryStore: directoryStore,
            secretStore: FakeSecretStore(),
            stateReader: StubStateReader(result: result)
        )

        let diagnostic = manager.diagnostics.first { $0.id == "quota" }
        XCTAssertEqual(diagnostic?.level, .success)
        XCTAssertTrue(diagnostic?.detail.contains("最近一次官方可见周额度") == true)
        XCTAssertTrue(diagnostic?.detail.contains("界面暂时被遮挡") == true)
    }

    private func makeFixture() throws -> (
        manager: AccountManager,
        secretStore: FakeSecretStore,
        result: TypelessStateReadResult,
        fileURL: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = root.appendingPathComponent("accounts.json")
        let secretStore = FakeSecretStore()
        let result = makeReadResult(root: root)
        let manager = AccountManager(
            directoryStore: AccountDirectoryStore(fileURL: fileURL),
            secretStore: secretStore,
            stateReader: StubStateReader(result: result)
        )
        return (manager, secretStore, result, fileURL)
    }

    private func makeReadResult(
        root: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    ) -> TypelessStateReadResult {
        let quota = QuotaSnapshot(
            usedCharacters: 1_000,
            limitCharacters: 8_000,
            observedAt: Date(timeIntervalSince1970: 5_000),
            source: .typelessAccessibility
        )
        let state = CurrentTypelessState(
            email: "person@example.com",
            displayName: "Person",
            planName: "Free",
            quota: quota,
            observedAt: Date(timeIntervalSince1970: 5_000),
            sourceModifiedAt: Date(timeIntervalSince1970: 4_900)
        )
        return TypelessStateReadResult(
            state: state,
            storageURL: root.appendingPathComponent("app-storage.json"),
            appVersion: "2.4.0",
            appRunning: true
        )
    }
}
