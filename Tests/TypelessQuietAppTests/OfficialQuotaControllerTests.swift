import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

final class ControlledQuotaFetcher: OfficialQuotaFetching, @unchecked Sendable {
    struct Call {
        let email: String
        let revision: String
        let continuation: CheckedContinuation<OfficialQuotaObservation, Error>
    }
    private let lock = NSLock()
    private var storedRevision = "one"
    private var storedCalls: [Call] = []
    private var storedRevisionReads = 0
    var revision: String {
        get { lock.withLock { storedRevision } }
        set { lock.withLock { storedRevision = newValue } }
    }
    var calls: [Call] { lock.withLock { storedCalls } }
    var revisionReads: Int { lock.withLock { storedRevisionReads } }
    func sessionRevision() throws -> String {
        lock.withLock { storedRevisionReads += 1; return storedRevision }
    }
    func fetch(email: String, revision: String) async throws -> OfficialQuotaObservation {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { storedCalls.append(Call(email: email, revision: revision, continuation: continuation)) }
        }
    }
    func succeed(_ index: Int, at date: Date, used: Int = 652) {
        let call = calls[index]
        call.continuation.resume(returning: OfficialQuotaObservation(email: call.email, revision: call.revision,
            quota: QuotaSnapshot(usedCharacters: used, limitCharacters: 8_000,
                                 observedAt: date, source: .typelessOfficialAPI)))
    }
    func fail(_ index: Int, _ code: OfficialQuotaFailureCode, retryAfter: TimeInterval? = nil) {
        calls[index].continuation.resume(throwing: OfficialQuotaFailure(code: code, retryAfter: retryAfter))
    }
}

@MainActor
final class OfficialQuotaControllerTests: XCTestCase {
    private let email = "current@example.com"
    private var date = Date(timeIntervalSince1970: 2_000)

    func testDisabledModeDoesNotReadSessionOrRequestUntilExplicitlyEnabled() async throws {
        let fetcher = ControlledQuotaFetcher()
        var saved: [Bool] = []
        let controller = OfficialQuotaController(fetcher: fetcher, persistEnabled: { saved.append($0) })
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.observe(email: email))
        controller.requestRefresh(force: true)
        XCTAssertEqual(fetcher.revisionReads, 0)
        XCTAssertEqual(fetcher.calls.count, 0)
        controller.setEnabled(true)
        XCTAssertTrue(controller.observe(email: email))
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 1 }
        controller.setEnabled(false)
        fetcher.succeed(0, at: Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(saved, [true, false])
        XCTAssertNil(controller.cachedQuota(for: email))
        XCTAssertFalse(controller.isRefreshing)
    }

    func testBurstJoinsOneRequestAndCompletionDoesNotPoll() async throws {
        let fetcher = ControlledQuotaFetcher()
        let controller = makeController(fetcher)
        controller.observe(email: email)
        for _ in 0..<20 { controller.requestRefresh() }
        try await eventually { fetcher.calls.count == 1 }
        fetcher.succeed(0, at: date)
        try await eventually { !controller.isRefreshing }
        XCTAssertEqual(controller.cachedQuota(for: email)?.usedCharacters, 652)
        date.addTimeInterval(61)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(fetcher.calls.count, 1)
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 2 }
        fetcher.succeed(1, at: date)
        try await eventually { !controller.isRefreshing }
    }

    func testLateResultCannotReplaceNewAccountOrNewSession() async throws {
        let fetcher = ControlledQuotaFetcher()
        let controller = makeController(fetcher)
        controller.observe(email: email)
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 1 }
        fetcher.revision = "two"
        controller.observe(email: "new@example.com")
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 2 }
        fetcher.succeed(1, at: date, used: 123)
        try await eventually { !controller.isRefreshing }
        fetcher.succeed(0, at: date, used: 7_900)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.cachedQuota(for: "new@example.com")?.usedCharacters, 123)
        XCTAssertNil(controller.cachedQuota(for: email))
        fetcher.revision = "three"
        XCTAssertTrue(controller.observe(email: "new@example.com"))
        XCTAssertNil(controller.cachedQuota(for: "new@example.com"))
    }

    func testSessionRevisionChangedBeforeCompletionIsRejected() async throws {
        let fetcher = ControlledQuotaFetcher()
        let controller = makeController(fetcher)
        controller.observe(email: email)
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 1 }
        fetcher.revision = "two"
        fetcher.succeed(0, at: date)
        try await eventually { !controller.isRefreshing }
        XCTAssertNil(controller.cachedQuota(for: email))
        XCTAssertEqual(controller.failure?.code, .sessionChanged)
    }

    func testFailuresPreserveTimestampAndRespectRetryAfterEvenForManualRefresh() async throws {
        let fetcher = ControlledQuotaFetcher()
        let controller = makeController(fetcher)
        controller.observe(email: email)
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 1 }
        fetcher.succeed(0, at: date)
        try await eventually { !controller.isRefreshing }
        let original = controller.cachedQuota(for: email)
        date.addTimeInterval(61)
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 2 }
        fetcher.fail(1, .rateLimited, retryAfter: 120)
        try await eventually { !controller.isRefreshing }
        XCTAssertEqual(controller.cachedQuota(for: email), original)
        XCTAssertEqual(controller.nextAttemptAt, date.addingTimeInterval(120))
        date.addTimeInterval(119)
        controller.requestRefresh(force: true)
        XCTAssertEqual(fetcher.calls.count, 2)
        date.addTimeInterval(2)
        controller.requestRefresh(force: true)
        try await eventually { fetcher.calls.count == 3 }
        fetcher.fail(2, .unauthorized)
        try await eventually { !controller.isRefreshing }
        XCTAssertNil(controller.cachedQuota(for: email))
    }

    func testExpiredQuotaNeverGetsNewTimestampAndForceHasCooldown() async throws {
        let fetcher = ControlledQuotaFetcher()
        let controller = makeController(fetcher)
        controller.observe(email: email)
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 1 }
        fetcher.succeed(0, at: date)
        try await eventually { !controller.isRefreshing }
        date.addTimeInterval(4)
        controller.requestRefresh(force: true)
        XCTAssertEqual(fetcher.calls.count, 1)
        date.addTimeInterval(297)
        XCTAssertNil(controller.cachedQuota(for: email))
        XCTAssertEqual(fetcher.calls.count, 1)
    }

    func testDeferredEventRunsOnceWithoutRecurringNetworkWork() async throws {
        let fetcher = ControlledQuotaFetcher()
        let controller = OfficialQuotaController(fetcher: fetcher, isEnabled: true, now: { self.date })
        controller.observe(email: email)
        controller.requestRefresh()
        try await eventually { fetcher.calls.count == 1 }
        fetcher.succeed(0, at: date)
        try await eventually { !controller.isRefreshing }
        date.addTimeInterval(59.99)
        controller.requestRefresh()
        date.addTimeInterval(1)
        try await eventually { fetcher.calls.count == 2 }
        fetcher.succeed(1, at: date)
        try await eventually { !controller.isRefreshing }
        date.addTimeInterval(61)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fetcher.calls.count, 2)
        controller.setEnabled(false)
    }

    private func makeController(_ fetcher: ControlledQuotaFetcher) -> OfficialQuotaController {
        OfficialQuotaController(fetcher: fetcher, isEnabled: true, now: { self.date }, schedulesDeferredEvents: false)
    }
    private func eventually(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Quota operation did not settle")
    }
}
