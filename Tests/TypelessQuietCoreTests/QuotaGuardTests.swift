import XCTest
@testable import TypelessQuietCore

final class QuotaGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 40_000)

    func testConfigurationDefaultsDisabledAndNormalizesBounds() {
        XCTAssertFalse(QuotaGuardConfiguration().isEnabled)
        XCTAssertEqual(QuotaGuardConfiguration().thresholdCharacters, 500)
        XCTAssertEqual(QuotaGuardConfiguration().cooldownMinutes, 30)

        let normalized = QuotaGuardConfiguration(
            isEnabled: true,
            thresholdCharacters: -20,
            accountPool: [],
            cooldownMinutes: 10_000
        )
        XCTAssertEqual(normalized.thresholdCharacters, 0)
        XCTAssertEqual(normalized.cooldownMinutes, 1_440)
    }

    func testDecodedConfigurationAndRuntimeNormalizeUnsafeCounts() throws {
        let json = #"{"accountPool":[],"cooldownMinutes":9999,"isEnabled":false,"thresholdCharacters":-50}"#
        let configuration = try JSONDecoder().decode(
            QuotaGuardConfiguration.self,
            from: Data(json.utf8)
        )
        let runtimeJSON = #"{"consecutiveFailures":-8}"#
        let runtime = try JSONDecoder().decode(
            QuotaGuardRuntime.self,
            from: Data(runtimeJSON.utf8)
        )

        XCTAssertEqual(configuration.thresholdCharacters, 0)
        XCTAssertEqual(configuration.cooldownMinutes, 1_440)
        XCTAssertEqual(runtime.consecutiveFailures, 0)
    }

    func testDisabledGuardNeverTriggers() throws {
        var fixture = try makeFixture()
        fixture.configuration.isEnabled = false

        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.disabled)
        )
    }

    func testDoesNothingWhenCurrentQuotaIsAtOrAboveThreshold() throws {
        var fixture = try makeFixture()
        fixture.currentState.quota?.usedCharacters = 7_500

        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.quotaSufficient)
        )
    }

    func testRejectsMissingAndStaleCurrentQuota() throws {
        var fixture = try makeFixture()
        fixture.currentState.quota = nil
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.currentQuotaMissing)
        )

        fixture = try makeFixture()
        fixture.currentState.quota?.observedAt = now.addingTimeInterval(-301)
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.currentQuotaStale)
        )
    }

    func testRejectsRecordingProcessingAndUnknownActivity() throws {
        for (activity, reason) in [
            (TypelessActivityState.recording, QuotaGuardNoActionReason.activityRecording),
            (.processing, .activityProcessing),
        ] {
            var fixture = try makeFixture()
            fixture.currentState.activity = activity
            XCTAssertEqual(
                QuotaGuardPolicy.evaluate(fixture.input(now: now)),
                .noAction(reason)
            )
        }
    }

    func testUnknownActivityOffersActionWithoutAutomaticSwitch() throws {
        var fixture = try makeFixture()
        fixture.currentState.activity = .unknown
        XCTAssertEqual(QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .needsManualVerification(fixture.targetA.id))
    }

    func testRejectsBusySwitchAndStoppedTypeless() throws {
        var fixture = try makeFixture()
        fixture.switchBusy = true
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.switchInProgress)
        )

        fixture = try makeFixture()
        fixture.typelessRunning = false
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.typelessNotRunning)
        )
    }

    func testPoolMustBeUniqueCompleteAndContainCurrentAccount() throws {
        var fixture = try makeFixture()
        fixture.configuration.accountPool = [fixture.current.id, fixture.targetA.id, fixture.targetA.id]
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.poolAmbiguous)
        )

        fixture = try makeFixture()
        fixture.configuration.accountPool = [fixture.targetA.id, fixture.targetB.id]
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.poolAmbiguous)
        )

        fixture = try makeFixture()
        fixture.configuration.accountPool.append(UUID())
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.poolAmbiguous)
        )
    }

    func testSelectsFirstFreshAvailableTargetInPoolOrder() throws {
        var fixture = try makeFixture()
        fixture.accounts[1].status = .paused

        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .trigger(fixture.targetB.id)
        )
    }

    func testStaleCandidateOffersManualVerificationWithoutTrustingOldQuota() throws {
        var fixture = try makeFixture()
        fixture.accounts[1].quota?.observedAt = now.addingTimeInterval(-301)
        fixture.accounts[2].quota?.usedCharacters = 7_900

        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .needsManualVerification(fixture.targetA.id)
        )
    }

    func testCooldownUsesExponentialBackoffAndCapsAtTwentyFourHours() throws {
        var fixture = try makeFixture()
        fixture.runtime.lastAttemptAt = now.addingTimeInterval(-1_000)
        fixture.runtime.consecutiveFailures = 0
        XCTAssertEqual(
            QuotaGuardPolicy.evaluate(fixture.input(now: now)),
            .noAction(.cooldown)
        )
        XCTAssertEqual(
            QuotaGuardPolicy.nextEligibleAt(
                configuration: fixture.configuration,
                runtime: fixture.runtime
            ),
            fixture.runtime.lastAttemptAt?.addingTimeInterval(1_800)
        )

        fixture.runtime.consecutiveFailures = 3
        XCTAssertEqual(
            QuotaGuardPolicy.effectiveCooldown(
                configuration: fixture.configuration,
                runtime: fixture.runtime
            ),
            14_400
        )

        fixture.configuration.cooldownMinutes = 1_440
        fixture.runtime.consecutiveFailures = 30
        XCTAssertEqual(
            QuotaGuardPolicy.effectiveCooldown(
                configuration: fixture.configuration,
                runtime: fixture.runtime
            ),
            86_400
        )
    }

    func testRuntimeTracksAttemptSuccessAndFailureWithoutGoingNegative() {
        let targetID = UUID()
        var runtime = QuotaGuardRuntime(consecutiveFailures: -3)
        XCTAssertEqual(runtime.consecutiveFailures, 0)

        runtime.recordAttempt(targetAccountID: targetID, at: now)
        XCTAssertEqual(runtime.lastAttemptAt, now)
        XCTAssertEqual(runtime.lastTargetAccountID, targetID)

        runtime.recordResult(succeeded: false, at: now.addingTimeInterval(1))
        XCTAssertEqual(runtime.consecutiveFailures, 1)
        XCTAssertNil(runtime.lastSuccessAt)

        runtime.recordResult(succeeded: true, at: now.addingTimeInterval(2))
        XCTAssertEqual(runtime.consecutiveFailures, 0)
        XCTAssertEqual(runtime.lastSuccessAt, now.addingTimeInterval(2))
    }

    private func makeFixture() throws -> Fixture {
        var current = try AccountProfile(displayName: "Current", email: "current@example.test")
        var targetA = try AccountProfile(displayName: "Target A", email: "a@example.test")
        var targetB = try AccountProfile(displayName: "Target B", email: "b@example.test")
        current.quota = quota(remaining: 100)
        targetA.quota = quota(remaining: 3_000)
        targetB.quota = quota(remaining: 2_000)
        let configuration = QuotaGuardConfiguration(
            isEnabled: true,
            thresholdCharacters: 500,
            accountPool: [current.id, targetA.id, targetB.id],
            cooldownMinutes: 30
        )
        let state = CurrentTypelessState(
            email: current.email,
            displayName: current.displayName,
            planName: "Free",
            quota: current.quota,
            observedAt: now,
            sourceModifiedAt: now,
            activity: .idle
        )
        return Fixture(
            current: current,
            targetA: targetA,
            targetB: targetB,
            accounts: [current, targetA, targetB],
            currentState: state,
            configuration: configuration,
            runtime: QuotaGuardRuntime(),
            typelessRunning: true,
            switchBusy: false
        )
    }

    private func quota(remaining: Int) -> QuotaSnapshot {
        QuotaSnapshot(
            usedCharacters: 8_000 - remaining,
            limitCharacters: 8_000,
            observedAt: now.addingTimeInterval(-1),
            source: .typelessAccessibility
        )
    }

    private struct Fixture {
        let current: AccountProfile
        let targetA: AccountProfile
        let targetB: AccountProfile
        var accounts: [AccountProfile]
        var currentState: CurrentTypelessState
        var configuration: QuotaGuardConfiguration
        var runtime: QuotaGuardRuntime
        var typelessRunning: Bool
        var switchBusy: Bool

        func input(now: Date) -> QuotaGuardInput {
            QuotaGuardInput(
                configuration: configuration,
                runtime: runtime,
                accounts: accounts,
                currentState: currentState,
                typelessRunning: typelessRunning,
                switchBusy: switchBusy,
                now: now
            )
        }
    }
}
