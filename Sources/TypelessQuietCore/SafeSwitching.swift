import Foundation

public enum TypelessActivityState: String, Codable, Equatable, Sendable {
    case idle
    case recording
    case processing
    case unknown
}

public enum TypelessActivityDetector {
    private static let idleMarkers: Set<String> = [
        "click to start dictating",
        "点击开始录音",
        "點擊開始口述",
    ]

    private static let processingMarkers: Set<String> = [
        "typeless was still processing your last transcript",
        "typeless仍在处理您的上一个转录",
        "typeless 仍在處理您上次的轉錄",
        "typeless仍在處理你的上一次轉錄",
    ]

    private static let recordingMarkerPairs: [(cancel: String, finish: String)] = [
        ("cancel", "finish"),
        ("取消", "完成"),
    ]

    public static func detect(texts: [String]) -> TypelessActivityState {
        let normalized = Set(texts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        if !normalized.isDisjoint(with: processingMarkers) {
            return .processing
        }
        if recordingMarkerPairs.contains(where: {
            normalized.contains($0.cancel) && normalized.contains($0.finish)
        }) {
            return .recording
        }
        if !normalized.isDisjoint(with: idleMarkers) {
            return .idle
        }
        return .unknown
    }
}

public enum SwitchSource: String, Codable, Equatable, Sendable {
    case manual
    case quotaGuard
}

public enum SwitchPhase: String, Codable, Equatable, Sendable {
    case preflight
    case requestingSwitch
    case verifying
    case succeeded
    case failed
    case restoring
}

public enum SwitchOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case originalPreserved
    case originalRestored
    case recoveryRequired
    case verificationRequired
    case cancelled
}

public enum SwitchFailureCode: String, Codable, Error, Equatable, Sendable {
    case transactionInProgress
    case targetNotFound
    case targetNotAvailable
    case alreadyCurrent
    case typelessNotRunning
    case currentAccountUnreadable
    case currentAccountUnmanaged
    case currentQuotaMissing
    case currentQuotaStale
    case activityRecording
    case activityProcessing
    case activityUnknown
    case officialLoginOpenFailed
    case verificationTimedOut
    case verificationObservedDifferentAccount
    case verificationQuotaMissingOrStale
    case originalStateUnverified
    case cancelled
    case rollbackOpenFailed
    case rollbackTimedOut
    case auditWriteFailed
    case interrupted
}

public struct SwitchPreflightInput: Sendable {
    public var accounts: [AccountProfile]
    public var currentState: CurrentTypelessState
    public var typelessRunning: Bool
    public var targetAccountID: UUID
    public var source: SwitchSource
    public var hasActiveTransaction: Bool
    public var now: Date
    public var maximumQuotaAge: TimeInterval
    public var verificationTimeout: TimeInterval

    public init(
        accounts: [AccountProfile],
        currentState: CurrentTypelessState,
        typelessRunning: Bool,
        targetAccountID: UUID,
        source: SwitchSource,
        hasActiveTransaction: Bool,
        now: Date,
        maximumQuotaAge: TimeInterval = 300,
        verificationTimeout: TimeInterval = 90
    ) {
        self.accounts = accounts
        self.currentState = currentState
        self.typelessRunning = typelessRunning
        self.targetAccountID = targetAccountID
        self.source = source
        self.hasActiveTransaction = hasActiveTransaction
        self.now = now
        self.maximumQuotaAge = maximumQuotaAge
        self.verificationTimeout = verificationTimeout
    }
}

public struct SwitchPlan: Equatable, Sendable {
    public let transactionID: UUID
    public let originalAccountID: UUID
    public let targetAccountID: UUID
    public let originalEmail: String
    public let targetEmail: String
    public let source: SwitchSource
    public let requestedAt: Date
    public let verificationDeadline: Date

    public init(
        transactionID: UUID = UUID(),
        originalAccountID: UUID,
        targetAccountID: UUID,
        originalEmail: String,
        targetEmail: String,
        source: SwitchSource,
        requestedAt: Date,
        verificationDeadline: Date
    ) {
        self.transactionID = transactionID
        self.originalAccountID = originalAccountID
        self.targetAccountID = targetAccountID
        self.originalEmail = originalEmail
        self.targetEmail = targetEmail
        self.source = source
        self.requestedAt = requestedAt
        self.verificationDeadline = verificationDeadline
    }
}

public enum SwitchVerificationDecision: Equatable, Sendable {
    case pending
    case succeeded
    case originalPreserved(SwitchFailureCode)
    case requiresVerification(SwitchFailureCode)
    case requiresRollback(SwitchFailureCode)
}

public enum SwitchRollbackDecision: Equatable, Sendable {
    case pending
    case originalRestored
    case recoveryRequired(SwitchFailureCode)
}

public enum SwitchPolicy {
    public static func preflight(_ input: SwitchPreflightInput) throws -> SwitchPlan {
        guard !input.hasActiveTransaction else {
            throw SwitchFailureCode.transactionInProgress
        }
        guard let target = input.accounts.first(where: { $0.id == input.targetAccountID }) else {
            throw SwitchFailureCode.targetNotFound
        }
        guard target.status == .available || (input.source == .manual && target.status == .unknown) else {
            throw SwitchFailureCode.targetNotAvailable
        }
        guard input.typelessRunning else {
            throw SwitchFailureCode.typelessNotRunning
        }
        guard let currentEmail = input.currentState.email else {
            throw SwitchFailureCode.currentAccountUnreadable
        }
        guard let original = input.accounts.first(where: { $0.email == currentEmail }) else {
            throw SwitchFailureCode.currentAccountUnmanaged
        }
        guard original.id != target.id, original.email != target.email else {
            throw SwitchFailureCode.alreadyCurrent
        }
        // Manual login only opens the official site; the user controls when to authenticate.
        // Automated decisions still require a fresh quota and positive idle evidence.
        if input.source == .quotaGuard {
            guard let quota = input.currentState.quota, quota.limitCharacters > 0 else {
                throw SwitchFailureCode.currentQuotaMissing
            }
            guard quota.isFresh(at: input.now, maximumAge: input.maximumQuotaAge) else {
                throw SwitchFailureCode.currentQuotaStale
            }
        }
        switch input.currentState.activity {
        case .idle:
            break
        case .recording:
            throw SwitchFailureCode.activityRecording
        case .processing:
            throw SwitchFailureCode.activityProcessing
        case .unknown:
            if input.source == .quotaGuard { throw SwitchFailureCode.activityUnknown }
        }

        return SwitchPlan(
            originalAccountID: original.id,
            targetAccountID: target.id,
            originalEmail: original.email,
            targetEmail: target.email,
            source: input.source,
            requestedAt: input.now,
            verificationDeadline: input.now.addingTimeInterval(input.verificationTimeout)
        )
    }

    public static func verify(
        plan: SwitchPlan,
        state: CurrentTypelessState?,
        now: Date,
        maximumQuotaAge: TimeInterval = 300
    ) -> SwitchVerificationDecision {
        if let state,
           state.email == plan.targetEmail,
           let quota = state.quota,
           quota.limitCharacters > 0,
           quota.observedAt >= plan.requestedAt,
           quota.isFresh(at: now, maximumAge: maximumQuotaAge) {
            return .succeeded
        }
        guard now >= plan.verificationDeadline else {
            return .pending
        }
        guard let state else {
            return .requiresVerification(.verificationTimedOut)
        }
        if state.email == plan.originalEmail {
            if let quota = state.quota,
               quota.limitCharacters > 0,
               quota.observedAt >= plan.requestedAt,
               quota.isFresh(at: now, maximumAge: maximumQuotaAge) {
                return .originalPreserved(.verificationTimedOut)
            }
            return .originalPreserved(.originalStateUnverified)
        }
        if state.email == plan.targetEmail {
            return .requiresVerification(.verificationQuotaMissingOrStale)
        }
        return .requiresRollback(.verificationObservedDifferentAccount)
    }

    public static func verifyRollback(
        plan: SwitchPlan,
        state: CurrentTypelessState?,
        rollbackRequestedAt: Date,
        rollbackDeadline: Date,
        now: Date,
        maximumQuotaAge: TimeInterval = 300
    ) -> SwitchRollbackDecision {
        if let state,
           state.email == plan.originalEmail,
           let quota = state.quota,
           quota.limitCharacters > 0,
           quota.observedAt >= rollbackRequestedAt,
           quota.isFresh(at: now, maximumAge: maximumQuotaAge) {
            return .originalRestored
        }
        guard now >= rollbackDeadline else {
            return .pending
        }
        return .recoveryRequired(.rollbackTimedOut)
    }
}

public struct SwitchAuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let transactionID: UUID
    public let originalAccountID: UUID?
    public let targetAccountID: UUID
    public let source: SwitchSource
    public let phase: SwitchPhase
    public let occurredAt: Date
    public let outcome: SwitchOutcome?
    public let failureCode: SwitchFailureCode?

    public init(
        id: UUID = UUID(),
        transactionID: UUID,
        originalAccountID: UUID?,
        targetAccountID: UUID,
        source: SwitchSource,
        phase: SwitchPhase,
        occurredAt: Date,
        outcome: SwitchOutcome? = nil,
        failureCode: SwitchFailureCode? = nil
    ) {
        self.id = id
        self.transactionID = transactionID
        self.originalAccountID = originalAccountID
        self.targetAccountID = targetAccountID
        self.source = source
        self.phase = phase
        self.occurredAt = occurredAt
        self.outcome = outcome
        self.failureCode = failureCode
    }
}

public struct SwitchAuditLog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var events: [SwitchAuditEvent]

    public init(
        schemaVersion: Int = SwitchAuditLog.currentSchemaVersion,
        events: [SwitchAuditEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.events = events
    }
}
