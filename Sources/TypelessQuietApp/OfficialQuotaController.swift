import Foundation
import TypelessQuietCore

/// Event-driven refresh with one in-flight request and at most one deferred event.
/// Completion alone never starts another request; there is no recurring network timer.
@MainActor
final class OfficialQuotaController {
    static let preferenceKey = "TypelessOfficialQuotaEnabled"
    private(set) var isEnabled: Bool
    private(set) var isRefreshing = false
    private(set) var failure: OfficialQuotaFailure?
    private(set) var nextAttemptAt: Date?
    var onUpdate: (() -> Void)?

    private struct Context: Equatable {
        let email: String
        let revision: String
    }
    private let fetcher: any OfficialQuotaFetching
    private let now: () -> Date
    private let persistEnabled: (Bool) -> Void
    private let schedulesDeferredEvents: Bool
    private var context: Context?
    private var observation: OfficialQuotaObservation?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var deferredEvent: DispatchWorkItem?
    private var eventDuringRequest = false
    private var lastAttemptAt: Date?
    private var failureRetryAt: Date?
    private var failureCount = 0

    init(fetcher: any OfficialQuotaFetching, isEnabled: Bool = false,
         now: @escaping () -> Date = Date.init, schedulesDeferredEvents: Bool = true,
         persistEnabled: @escaping (Bool) -> Void = { _ in }) {
        self.fetcher = fetcher
        self.isEnabled = isEnabled
        self.now = now
        self.persistEnabled = persistEnabled
        self.schedulesDeferredEvents = schedulesDeferredEvents
    }

    deinit { task?.cancel(); deferredEvent?.cancel() }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        persistEnabled(enabled)
        clearContext()
    }

    /// Cheap encrypted-file revision check; disabled mode does not read the session.
    @discardableResult
    func observe(email: String?) -> Bool {
        guard isEnabled else { return false }
        guard let email = email.flatMap(AccountProfile.normalizedEmail) else {
            clearContext()
            failure = OfficialQuotaFailure(code: .sessionUnavailable)
            return false
        }
        do {
            let latest = Context(email: email, revision: try fetcher.sessionRevision())
            guard latest != context else { return false }
            clearContext()
            context = latest
            return true
        } catch {
            clearContext()
            failure = (error as? OfficialQuotaFailure) ?? OfficialQuotaFailure(code: .sessionUnavailable)
            return false
        }
    }

    func cachedQuota(for email: String?) -> QuotaSnapshot? {
        guard isEnabled, let context, context.email == email,
              let observation, observation.email == context.email, observation.revision == context.revision,
              observation.quota.isFresh(at: now()) else { return nil }
        return observation.quota
    }

    func requestRefresh(force: Bool = false) {
        guard isEnabled, let context else { return }
        guard task == nil else {
            eventDuringRequest = true
            return
        }
        let date = now()
        let earliest = force ? lastAttemptAt?.addingTimeInterval(5) : nextAttemptAt
        let permittedAt = [earliest, failureRetryAt].compactMap { $0 }.max()
        if let permittedAt, date < permittedAt {
            scheduleEvent(at: permittedAt)
            return
        }
        deferredEvent?.cancel()
        deferredEvent = nil
        isRefreshing = true
        lastAttemptAt = date
        eventDuringRequest = false
        let requestedGeneration = generation
        let fetcher = fetcher
        task = Task { [weak self] in
            let result: Result<OfficialQuotaObservation, Error>
            do { result = .success(try await fetcher.fetch(email: context.email, revision: context.revision)) }
            catch { result = .failure(error) }
            self?.finish(result, context: context, generation: requestedGeneration)
        }
    }

    private func finish(_ result: Result<OfficialQuotaObservation, Error>, context: Context, generation: Int) {
        guard isEnabled, self.generation == generation, self.context == context else { return }
        task = nil
        isRefreshing = false
        let date = now()
        switch result {
        case let .success(value):
            guard value.email == context.email, value.revision == context.revision,
                  (try? fetcher.sessionRevision()) == context.revision else {
                observation = nil
                failure = OfficialQuotaFailure(code: .sessionChanged)
                nextAttemptAt = nil
                onUpdate?()
                return
            }
            observation = value
            failure = nil
            failureCount = 0
            failureRetryAt = nil
            nextAttemptAt = date.addingTimeInterval(60)
        case let .failure(error):
            let issue = (error as? OfficialQuotaFailure) ?? OfficialQuotaFailure(code: .networkUnavailable)
            failure = issue
            failureCount = min(6, failureCount + 1)
            let delay = max(min(900, 30 * pow(2, Double(failureCount - 1))),
                            min(86_400, max(0, issue.retryAfter ?? 0)))
            failureRetryAt = date.addingTimeInterval(delay)
            nextAttemptAt = failureRetryAt
            if [.sessionChanged, .identityMismatch, .unauthorized, .invalidSession].contains(issue.code) {
                observation = nil
            }
        }
        let pending = eventDuringRequest
        eventDuringRequest = false
        onUpdate?()
        if pending, self.generation == generation, let nextAttemptAt { scheduleEvent(at: nextAttemptAt) }
    }

    private func scheduleEvent(at date: Date) {
        guard schedulesDeferredEvents, deferredEvent == nil else { return }
        let requestedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == requestedGeneration else { return }
            self.deferredEvent = nil
            // Re-observe through the owner before using a possibly changed account.
            self.onUpdate?()
            if self.generation == requestedGeneration, self.task == nil { self.requestRefresh() }
        }
        deferredEvent = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, date.timeIntervalSince(now())), execute: work)
    }

    private func clearContext() {
        generation &+= 1
        task?.cancel()
        task = nil
        deferredEvent?.cancel()
        deferredEvent = nil
        eventDuringRequest = false
        context = nil
        observation = nil
        failure = nil
        failureCount = 0
        failureRetryAt = nil
        nextAttemptAt = nil
        lastAttemptAt = nil
        isRefreshing = false
    }
}
