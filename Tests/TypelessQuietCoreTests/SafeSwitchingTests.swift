import XCTest
@testable import TypelessQuietCore

final class SafeSwitchingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)

    func testManualLoginCanVerifyUnknownTargetWithoutClaimingIdle() throws {
        let fixture = try makeFixture()
        var target = fixture.targetAccount
        target.status = .unknown
        var state = fixture.currentState
        state.activity = .unknown
        state.quota = nil
        XCTAssertNoThrow(try SwitchPolicy.preflight(SwitchPreflightInput(
            accounts: [fixture.currentAccount, target], currentState: state,
            typelessRunning: true, targetAccountID: target.id, source: .manual,
            hasActiveTransaction: false, now: now)))
        XCTAssertEqual(state.activity, .unknown)
    }

    func testActivityDetectorRequiresExplicitIdleEvidence() {
        XCTAssertEqual(
            TypelessActivityDetector.detect(texts: ["Click to start dictating"]),
            .idle
        )
        XCTAssertEqual(
            TypelessActivityDetector.detect(texts: ["点击开始录音"]),
            .idle
        )
        XCTAssertEqual(
            TypelessActivityDetector.detect(texts: ["Cancel", "Finish"]),
            .recording
        )
        XCTAssertEqual(
            TypelessActivityDetector.detect(texts: [
                "Click to start dictating",
                "Typeless was still processing your last transcript",
            ]),
            .processing
        )
        XCTAssertEqual(TypelessActivityDetector.detect(texts: ["Dictate"]), .unknown)
    }

    func testPreflightBuildsPlanForManagedIdleCurrentAccount() throws {
        let fixture = try makeFixture()

        let plan = try SwitchPolicy.preflight(SwitchPreflightInput(
            accounts: [fixture.currentAccount, fixture.targetAccount],
            currentState: fixture.currentState,
            typelessRunning: true,
            targetAccountID: fixture.targetAccount.id,
            source: .manual,
            hasActiveTransaction: false,
            now: now
        ))

        XCTAssertEqual(plan.originalAccountID, fixture.currentAccount.id)
        XCTAssertEqual(plan.targetAccountID, fixture.targetAccount.id)
        XCTAssertEqual(plan.originalEmail, fixture.currentAccount.email)
        XCTAssertEqual(plan.targetEmail, fixture.targetAccount.email)
        XCTAssertEqual(plan.requestedAt, now)
        XCTAssertEqual(plan.verificationDeadline, now.addingTimeInterval(90))
    }

    func testPreflightRejectsEveryUnsafeActivityState() throws {
        let fixture = try makeFixture()
        for (activity, expected) in [
            (TypelessActivityState.recording, SwitchFailureCode.activityRecording),
            (.processing, .activityProcessing),
            (.unknown, .activityUnknown),
        ] {
            var state = fixture.currentState
            state.activity = activity

            XCTAssertThrowsError(try SwitchPolicy.preflight(SwitchPreflightInput(
                accounts: [fixture.currentAccount, fixture.targetAccount],
                currentState: state,
                typelessRunning: true,
                targetAccountID: fixture.targetAccount.id,
                source: .quotaGuard,
                hasActiveTransaction: false,
                now: now
            ))) {
                XCTAssertEqual($0 as? SwitchFailureCode, expected)
            }
        }
    }

    func testPreflightRejectsMissingOrStaleCurrentQuota() throws {
        let fixture = try makeFixture()
        var missing = fixture.currentState
        missing.quota = nil
        XCTAssertPreflightFailure(.currentQuotaMissing, state: missing, fixture: fixture)

        var stale = fixture.currentState
        stale.quota?.observedAt = now.addingTimeInterval(-301)
        XCTAssertPreflightFailure(.currentQuotaStale, state: stale, fixture: fixture)
    }

    func testPreflightRejectsUnmanagedCurrentPausedTargetSameTargetAndConcurrency() throws {
        let fixture = try makeFixture()
        XCTAssertPreflightFailure(
            .currentAccountUnmanaged,
            state: fixture.currentState,
            fixture: fixture,
            accounts: [fixture.targetAccount]
        )

        var paused = fixture.targetAccount
        paused.status = .paused
        XCTAssertPreflightFailure(
            .targetNotAvailable,
            state: fixture.currentState,
            fixture: fixture,
            accounts: [fixture.currentAccount, paused]
        )

        XCTAssertPreflightFailure(
            .alreadyCurrent,
            state: fixture.currentState,
            fixture: fixture,
            targetAccountID: fixture.currentAccount.id
        )

        XCTAssertPreflightFailure(
            .transactionInProgress,
            state: fixture.currentState,
            fixture: fixture,
            hasActiveTransaction: true
        )
    }

    func testPreflightRejectsMissingTargetStoppedTypelessAndUnreadableIdentity() throws {
        let fixture = try makeFixture()
        XCTAssertPreflightFailure(
            .targetNotFound,
            state: fixture.currentState,
            fixture: fixture,
            targetAccountID: UUID()
        )

        XCTAssertThrowsError(try SwitchPolicy.preflight(SwitchPreflightInput(
            accounts: [fixture.currentAccount, fixture.targetAccount],
            currentState: fixture.currentState,
            typelessRunning: false,
            targetAccountID: fixture.targetAccount.id,
            source: .manual,
            hasActiveTransaction: false,
            now: now
        ))) {
            XCTAssertEqual($0 as? SwitchFailureCode, .typelessNotRunning)
        }

        var unreadable = fixture.currentState
        unreadable.email = nil
        XCTAssertPreflightFailure(.currentAccountUnreadable, state: unreadable, fixture: fixture)
    }

    func testVerificationRequiresTargetEmailAndPostRequestFreshQuota() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan(now: now)
        let targetState = CurrentTypelessState(
            email: fixture.targetAccount.email,
            displayName: fixture.targetAccount.displayName,
            planName: "Free",
            quota: QuotaSnapshot(
                usedCharacters: 200,
                limitCharacters: 8_000,
                observedAt: now.addingTimeInterval(2),
                source: .typelessAccessibility
            ),
            observedAt: now.addingTimeInterval(2),
            sourceModifiedAt: now.addingTimeInterval(1),
            activity: .idle
        )

        XCTAssertEqual(
            SwitchPolicy.verify(plan: plan, state: targetState, now: now.addingTimeInterval(3)),
            .succeeded
        )

        var oldQuota = targetState
        oldQuota.quota?.observedAt = now.addingTimeInterval(-1)
        XCTAssertEqual(
            SwitchPolicy.verify(plan: plan, state: oldQuota, now: now.addingTimeInterval(3)),
            .pending
        )
    }

    func testVerificationTimeoutPreservesOriginalOrRequiresRollback() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan(now: now)
        var refreshedOriginal = fixture.currentState
        refreshedOriginal.quota?.observedAt = now.addingTimeInterval(1)

        XCTAssertEqual(
            SwitchPolicy.verify(
                plan: plan,
                state: refreshedOriginal,
                now: plan.verificationDeadline
            ),
            .originalPreserved(.verificationTimedOut)
        )

        XCTAssertEqual(
            SwitchPolicy.verify(
                plan: plan,
                state: fixture.currentState,
                now: plan.verificationDeadline
            ),
            .originalPreserved(.originalStateUnverified)
        )

        var wrong = fixture.currentState
        wrong.email = "unexpected@example.test"
        XCTAssertEqual(
            SwitchPolicy.verify(plan: plan, state: wrong, now: plan.verificationDeadline),
            .requiresRollback(.verificationObservedDifferentAccount)
        )

        var targetWithoutQuota = fixture.currentState
        targetWithoutQuota.email = fixture.targetAccount.email
        targetWithoutQuota.quota = nil
        XCTAssertEqual(
            SwitchPolicy.verify(
                plan: plan,
                state: targetWithoutQuota,
                now: plan.verificationDeadline
            ),
            .requiresVerification(.verificationQuotaMissingOrStale)
        )
    }

    func testRollbackRequiresOriginalEmailAndFreshPostRequestQuota() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan(now: now)
        let rollbackRequestedAt = now.addingTimeInterval(100)
        var original = fixture.currentState
        original.quota?.observedAt = rollbackRequestedAt.addingTimeInterval(1)

        XCTAssertEqual(
            SwitchPolicy.verifyRollback(
                plan: plan,
                state: original,
                rollbackRequestedAt: rollbackRequestedAt,
                rollbackDeadline: rollbackRequestedAt.addingTimeInterval(90),
                now: rollbackRequestedAt.addingTimeInterval(2)
            ),
            .originalRestored
        )

        original.quota?.observedAt = rollbackRequestedAt.addingTimeInterval(-1)
        XCTAssertEqual(
            SwitchPolicy.verifyRollback(
                plan: plan,
                state: original,
                rollbackRequestedAt: rollbackRequestedAt,
                rollbackDeadline: rollbackRequestedAt.addingTimeInterval(90),
                now: rollbackRequestedAt.addingTimeInterval(2)
            ),
            .pending
        )

        XCTAssertEqual(
            SwitchPolicy.verifyRollback(
                plan: plan,
                state: original,
                rollbackRequestedAt: rollbackRequestedAt,
                rollbackDeadline: rollbackRequestedAt.addingTimeInterval(90),
                now: rollbackRequestedAt.addingTimeInterval(90)
            ),
            .recoveryRequired(.rollbackTimedOut)
        )
    }

    func testAuditEventsEncodeOnlyIDsPhasesAndRedactedCodes() throws {
        let originalID = UUID()
        let targetID = UUID()
        let event = SwitchAuditEvent(
            transactionID: UUID(),
            originalAccountID: originalID,
            targetAccountID: targetID,
            source: .manual,
            phase: .failed,
            occurredAt: now,
            outcome: .originalPreserved,
            failureCode: .verificationTimedOut
        )

        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

        XCTAssertTrue(encoded.contains(targetID.uuidString))
        XCTAssertTrue(encoded.contains("verificationTimedOut"))
        XCTAssertFalse(encoded.contains("@"))
        XCTAssertFalse(encoded.lowercased().contains("token"))
        XCTAssertFalse(encoded.lowercased().contains("password"))
        XCTAssertFalse(encoded.lowercased().contains("cookie"))
    }

    private func XCTAssertPreflightFailure(
        _ expected: SwitchFailureCode,
        state: CurrentTypelessState,
        fixture: Fixture,
        accounts: [AccountProfile]? = nil,
        targetAccountID: UUID? = nil,
        hasActiveTransaction: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try SwitchPolicy.preflight(SwitchPreflightInput(
            accounts: accounts ?? [fixture.currentAccount, fixture.targetAccount],
            currentState: state,
            typelessRunning: true,
            targetAccountID: targetAccountID ?? fixture.targetAccount.id,
            source: .quotaGuard,
            hasActiveTransaction: hasActiveTransaction,
            now: now
        )), file: file, line: line) {
            XCTAssertEqual($0 as? SwitchFailureCode, expected, file: file, line: line)
        }
    }

    private func makeFixture() throws -> Fixture {
        let current = try AccountProfile(displayName: "Current", email: "current@example.test")
        let target = try AccountProfile(displayName: "Target", email: "target@example.test")
        let state = CurrentTypelessState(
            email: current.email,
            displayName: current.displayName,
            planName: "Free",
            quota: QuotaSnapshot(
                usedCharacters: 1_000,
                limitCharacters: 8_000,
                observedAt: now.addingTimeInterval(-5),
                source: .typelessAccessibility
            ),
            observedAt: now,
            sourceModifiedAt: now.addingTimeInterval(-5),
            activity: .idle
        )
        return Fixture(currentAccount: current, targetAccount: target, currentState: state)
    }

    private struct Fixture {
        let currentAccount: AccountProfile
        let targetAccount: AccountProfile
        let currentState: CurrentTypelessState

        func plan(now: Date) throws -> SwitchPlan {
            try SwitchPolicy.preflight(SwitchPreflightInput(
                accounts: [currentAccount, targetAccount],
                currentState: currentState,
                typelessRunning: true,
                targetAccountID: targetAccount.id,
                source: .manual,
                hasActiveTransaction: false,
                now: now
            ))
        }
    }
}
