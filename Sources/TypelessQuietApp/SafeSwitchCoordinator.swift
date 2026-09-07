import AppKit
import Combine
import Foundation
import TypelessQuietCore

protocol SwitchAuditStoring: Sendable {
    var fileURL: URL { get }
    func load() throws -> SwitchAuditLog
    func append(_ event: SwitchAuditEvent) throws -> SwitchAuditLog
}

enum SwitchAuditStoreError: LocalizedError {
    case invalidSchema

    var errorDescription: String? {
        switch self {
        case .invalidSchema: "切换审计数据版本不受支持"
        }
    }
}

struct SwitchAuditStore: SwitchAuditStoring {
    let fileURL: URL
    let maximumEventCount: Int

    init(fileURL: URL, maximumEventCount: Int = 500) {
        self.fileURL = fileURL
        self.maximumEventCount = max(1, maximumEventCount)
    }

    func load() throws -> SwitchAuditLog {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SwitchAuditLog()
        }
        let log = try JSONDecoder().decode(
            SwitchAuditLog.self,
            from: Data(contentsOf: fileURL)
        )
        guard log.schemaVersion == SwitchAuditLog.currentSchemaVersion else {
            throw SwitchAuditStoreError.invalidSchema
        }
        return log
    }

    func append(_ event: SwitchAuditEvent) throws -> SwitchAuditLog {
        var log = try load()
        log.events.append(event)
        if log.events.count > maximumEventCount {
            log.events = Array(log.events.suffix(maximumEventCount))
        }
        try save(log)
        return log
    }

    private func save(_ log: SwitchAuditLog) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(log).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

@MainActor
protocol OfficialTypelessLoginOpening {
    var loginURL: URL { get }
    func openLogin() -> Bool
}

@MainActor
struct OfficialTypelessLoginOpener: OfficialTypelessLoginOpening {
    static let defaultLoginURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.typeless.com"
        components.path = "/login"
        components.queryItems = [URLQueryItem(name: "client_platform", value: "macos")]
        return components.url!
    }()

    let loginURL: URL

    init() {
        loginURL = Self.defaultLoginURL
    }

    init(loginURL: URL) {
        self.loginURL = loginURL
    }

    func openLogin() -> Bool {
        guard loginURL.scheme == "https",
              loginURL.host == "www.typeless.com",
              loginURL.path == "/login"
        else {
            return false
        }
        return NSWorkspace.shared.open(loginURL)
    }
}

struct SwitchOperation: Identifiable, Equatable {
    let id: UUID
    var originalAccountID: UUID?
    let targetAccountID: UUID
    let source: SwitchSource
    var phase: SwitchPhase
    let startedAt: Date
    var verificationDeadline: Date?
    var rollbackRequestedAt: Date?
    var rollbackDeadline: Date?
    var outcome: SwitchOutcome?
    var failureCode: SwitchFailureCode?
}

@MainActor
final class SwitchCoordinator: ObservableObject {
    @Published private(set) var operation: SwitchOperation?
    @Published private(set) var auditEvents: [SwitchAuditEvent] = []
    @Published private(set) var auditError: String?

    private let accountManager: AccountManager
    private let loginOpener: any OfficialTypelessLoginOpening
    private let auditStore: any SwitchAuditStoring
    private let now: () -> Date
    private let verificationIntervalNanoseconds: UInt64
    private let verificationTimeout: TimeInterval
    private let backgroundVerificationEnabled: Bool
    private var activePlan: SwitchPlan?
    private var verificationTask: Task<Void, Never>?

    convenience init(accountManager: AccountManager) {
        self.init(
            accountManager: accountManager,
            loginOpener: OfficialTypelessLoginOpener(),
            auditStore: Self.defaultAuditStore(),
            verificationTimeout: 300
        )
    }

    init(
        accountManager: AccountManager,
        loginOpener: any OfficialTypelessLoginOpening,
        auditStore: any SwitchAuditStoring,
        now: @escaping () -> Date = Date.init,
        verificationIntervalNanoseconds: UInt64 = 1_000_000_000,
        verificationTimeout: TimeInterval = 90,
        backgroundVerificationEnabled: Bool = true
    ) {
        self.accountManager = accountManager
        self.loginOpener = loginOpener
        self.auditStore = auditStore
        self.now = now
        self.verificationIntervalNanoseconds = verificationIntervalNanoseconds
        self.verificationTimeout = verificationTimeout
        self.backgroundVerificationEnabled = backgroundVerificationEnabled
        loadAuditAndCloseInterruptedOperation()
    }

    deinit {
        verificationTask?.cancel()
    }

    var isBusy: Bool {
        guard let phase = operation?.phase else { return false }
        return [.preflight, .requestingSwitch, .verifying, .restoring].contains(phase)
    }

    var officialLoginURL: URL { loginOpener.loginURL }

    var canRecoverTerminalOperation: Bool {
        guard [.recoveryRequired, .verificationRequired].contains(operation?.outcome),
              let originalID = operation?.originalAccountID
        else {
            return false
        }
        return accountManager.accounts.contains { $0.id == originalID }
    }

    func startSwitch(to targetAccountID: UUID, source: SwitchSource = .manual) {
        guard !isBusy else { return }
        accountManager.refresh()
        let startedAt = now()
        guard auditError == nil else {
            setBlockedOperation(
                targetAccountID: targetAccountID,
                source: source,
                at: startedAt,
                failure: .auditWriteFailed
            )
            return
        }
        guard let result = accountManager.currentReadResult else {
            setBlockedOperation(
                targetAccountID: targetAccountID,
                source: source,
                at: startedAt,
                failure: .currentAccountUnreadable
            )
            return
        }

        do {
            let plan = try SwitchPolicy.preflight(SwitchPreflightInput(
                accounts: accountManager.accounts,
                currentState: result.state,
                typelessRunning: result.appRunning,
                targetAccountID: targetAccountID,
                source: source,
                hasActiveTransaction: isBusy,
                now: startedAt,
                verificationTimeout: verificationTimeout
            ))
            activePlan = plan
            operation = SwitchOperation(
                id: plan.transactionID,
                originalAccountID: plan.originalAccountID,
                targetAccountID: plan.targetAccountID,
                source: plan.source,
                phase: .preflight,
                startedAt: plan.requestedAt,
                verificationDeadline: plan.verificationDeadline
            )
            guard appendCurrentEvent() else {
                failWithoutOpening(.auditWriteFailed)
                return
            }

            operation?.phase = .requestingSwitch
            guard appendCurrentEvent() else {
                failWithoutOpening(.auditWriteFailed)
                return
            }
            guard loginOpener.openLogin() else {
                finish(
                    phase: .failed,
                    outcome: .originalPreserved,
                    failure: .officialLoginOpenFailed
                )
                return
            }

            operation?.phase = .verifying
            _ = appendCurrentEvent()
            startVerificationLoopIfNeeded()
        } catch let failure as SwitchFailureCode {
            setBlockedOperation(
                targetAccountID: targetAccountID,
                source: source,
                at: startedAt,
                failure: failure
            )
        } catch {
            setBlockedOperation(
                targetAccountID: targetAccountID,
                source: source,
                at: startedAt,
                failure: .currentAccountUnreadable
            )
        }
    }

    func pollOnce() {
        guard let plan = activePlan, let phase = operation?.phase else { return }
        accountManager.refresh()
        let state = accountManager.currentState
        let currentTime = now()

        switch phase {
        case .verifying:
            switch SwitchPolicy.verify(plan: plan, state: state, now: currentTime) {
            case .pending:
                break
            case .succeeded:
                finish(phase: .succeeded, outcome: .succeeded, failure: nil)
            case let .originalPreserved(failure):
                finish(phase: .failed, outcome: .originalPreserved, failure: failure)
            case let .requiresVerification(failure):
                finish(phase: .failed, outcome: .verificationRequired, failure: failure)
            case let .requiresRollback(failure):
                beginRollback(trigger: failure)
            }
        case .restoring:
            guard let rollbackRequestedAt = operation?.rollbackRequestedAt,
                  let rollbackDeadline = operation?.rollbackDeadline
            else {
                finish(phase: .failed, outcome: .recoveryRequired, failure: .rollbackTimedOut)
                return
            }
            switch SwitchPolicy.verifyRollback(
                plan: plan,
                state: state,
                rollbackRequestedAt: rollbackRequestedAt,
                rollbackDeadline: rollbackDeadline,
                now: currentTime
            ) {
            case .pending:
                break
            case .originalRestored:
                finish(phase: .failed, outcome: .originalRestored, failure: operation?.failureCode)
            case let .recoveryRequired(failure):
                finish(phase: .failed, outcome: .recoveryRequired, failure: failure)
            }
        default:
            break
        }
    }

    func cancelAndRestore() {
        guard let plan = activePlan, isBusy else { return }
        accountManager.refresh()
        if accountManager.currentState?.email == plan.originalEmail {
            finish(phase: .failed, outcome: .cancelled, failure: .cancelled)
        } else {
            beginRollback(trigger: .cancelled)
        }
    }

    var canResumeVerification: Bool {
        operation?.outcome == .verificationRequired && operation?.originalAccountID != nil
    }

    func resumeVerification() {
        guard canResumeVerification, let operation,
              let originalID = operation.originalAccountID,
              let original = accountManager.accounts.first(where: { $0.id == originalID }),
              let target = accountManager.accounts.first(where: { $0.id == operation.targetAccountID }) else { return }
        let requestedAt = now()
        activePlan = SwitchPlan(transactionID: operation.id,
            originalAccountID: original.id, targetAccountID: target.id,
            originalEmail: original.email, targetEmail: target.email, source: operation.source,
            requestedAt: requestedAt, verificationDeadline: requestedAt.addingTimeInterval(verificationTimeout))
        self.operation?.phase = .verifying
        self.operation?.outcome = nil
        self.operation?.failureCode = nil
        self.operation?.verificationDeadline = activePlan?.verificationDeadline
        guard appendCurrentEvent() else {
            finish(phase: .failed, outcome: .verificationRequired, failure: .auditWriteFailed)
            return
        }
        pollOnce()
        if isBusy { startVerificationLoopIfNeeded() }
    }

    func stopTracking() {
        guard isBusy else { return }
        finish(phase: .failed, outcome: .cancelled, failure: .cancelled)
    }

    func reopenOfficialLogin() {
        guard isBusy else { return }
        if !loginOpener.openLogin(), operation?.phase == .restoring {
            finish(phase: .failed, outcome: .recoveryRequired, failure: .rollbackOpenFailed)
        }
    }

    func dismissTerminalOperation() {
        guard !isBusy else { return }
        operation = nil
        activePlan = nil
    }

    func recoverTerminalOperation() {
        guard canRecoverTerminalOperation,
              let operation,
              let originalID = operation.originalAccountID,
              let original = accountManager.accounts.first(where: { $0.id == originalID }),
              let target = accountManager.accounts.first(where: { $0.id == operation.targetAccountID })
        else {
            return
        }
        if activePlan == nil {
            activePlan = SwitchPlan(
                transactionID: operation.id,
                originalAccountID: original.id,
                targetAccountID: target.id,
                originalEmail: original.email,
                targetEmail: target.email,
                source: operation.source,
                requestedAt: operation.startedAt,
                verificationDeadline: now()
            )
        }
        beginRollback(trigger: operation.failureCode ?? .interrupted)
    }

    private func beginRollback(trigger: SwitchFailureCode) {
        guard activePlan != nil else { return }
        let requestedAt = now()
        operation?.phase = .restoring
        operation?.failureCode = trigger
        operation?.rollbackRequestedAt = requestedAt
        operation?.rollbackDeadline = requestedAt.addingTimeInterval(verificationTimeout)
        _ = appendCurrentEvent()
        guard loginOpener.openLogin() else {
            finish(phase: .failed, outcome: .recoveryRequired, failure: .rollbackOpenFailed)
            return
        }
        startVerificationLoopIfNeeded()
    }

    private func setBlockedOperation(
        targetAccountID: UUID,
        source: SwitchSource,
        at date: Date,
        failure: SwitchFailureCode
    ) {
        let transactionID = UUID()
        let originalID = accountManager.currentState?.email.flatMap { email in
            accountManager.directory.account(matchingEmail: email)?.id
        }
        operation = SwitchOperation(
            id: transactionID,
            originalAccountID: originalID,
            targetAccountID: targetAccountID,
            source: source,
            phase: .failed,
            startedAt: date,
            outcome: .originalPreserved,
            failureCode: failure
        )
        guard failure != .auditWriteFailed else { return }
        _ = appendCurrentEvent(phaseOverride: .preflight)
    }

    private func failWithoutOpening(_ failure: SwitchFailureCode) {
        operation?.phase = .failed
        operation?.outcome = .originalPreserved
        operation?.failureCode = failure
        verificationTask?.cancel()
    }

    private func finish(
        phase: SwitchPhase,
        outcome: SwitchOutcome,
        failure: SwitchFailureCode?
    ) {
        operation?.phase = phase
        operation?.outcome = outcome
        operation?.failureCode = failure
        _ = appendCurrentEvent()
        verificationTask?.cancel()
        verificationTask = nil
    }

    @discardableResult
    private func appendCurrentEvent(phaseOverride: SwitchPhase? = nil) -> Bool {
        guard let operation else { return false }
        let event = SwitchAuditEvent(
            transactionID: operation.id,
            originalAccountID: operation.originalAccountID,
            targetAccountID: operation.targetAccountID,
            source: operation.source,
            phase: phaseOverride ?? operation.phase,
            occurredAt: now(),
            outcome: operation.outcome,
            failureCode: operation.failureCode
        )
        do {
            let log = try auditStore.append(event)
            auditEvents = log.events
            return true
        } catch {
            auditError = error.localizedDescription
            return false
        }
    }

    private func startVerificationLoopIfNeeded() {
        guard backgroundVerificationEnabled, verificationTask == nil else { return }
        verificationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: self.verificationIntervalNanoseconds)
                } catch {
                    return
                }
                self.pollOnce()
                if !self.isBusy { return }
            }
        }
    }

    private func loadAuditAndCloseInterruptedOperation() {
        do {
            var log = try auditStore.load()
            auditEvents = log.events
            guard let last = log.events.last,
                  last.outcome == nil,
                  [.preflight, .requestingSwitch, .verifying, .restoring].contains(last.phase)
            else {
                return
            }
            let interrupted = SwitchAuditEvent(
                transactionID: last.transactionID,
                originalAccountID: last.originalAccountID,
                targetAccountID: last.targetAccountID,
                source: last.source,
                phase: .failed,
                occurredAt: now(),
                outcome: .recoveryRequired,
                failureCode: .interrupted
            )
            log = try auditStore.append(interrupted)
            auditEvents = log.events
            operation = SwitchOperation(
                id: last.transactionID,
                originalAccountID: last.originalAccountID,
                targetAccountID: last.targetAccountID,
                source: last.source,
                phase: .failed,
                startedAt: last.occurredAt,
                outcome: .recoveryRequired,
                failureCode: .interrupted
            )
        } catch {
            auditError = error.localizedDescription
        }
    }

    private static func defaultAuditStore() -> SwitchAuditStore {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["TYPELESS_PLUSPLUS_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Typeless++", isDirectory: true)
        }
        return SwitchAuditStore(fileURL: directory.appendingPathComponent("switch-audit.json"))
    }
}
