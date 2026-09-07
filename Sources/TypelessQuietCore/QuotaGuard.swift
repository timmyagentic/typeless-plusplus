import Foundation

public struct QuotaGuardConfiguration: Codable, Equatable, Sendable {
    public static let defaultThresholdCharacters = 500
    public static let defaultCooldownMinutes = 30

    public var isEnabled: Bool
    public var thresholdCharacters: Int
    public var accountPool: [UUID]
    public var cooldownMinutes: Int

    public init(
        isEnabled: Bool = false,
        thresholdCharacters: Int = QuotaGuardConfiguration.defaultThresholdCharacters,
        accountPool: [UUID] = [],
        cooldownMinutes: Int = QuotaGuardConfiguration.defaultCooldownMinutes
    ) {
        self.isEnabled = isEnabled
        self.thresholdCharacters = Self.normalizeThreshold(thresholdCharacters)
        self.accountPool = accountPool
        self.cooldownMinutes = Self.normalizeCooldownMinutes(cooldownMinutes)
    }

    public static func normalizeThreshold(_ value: Int) -> Int {
        min(max(value, 0), 50_000)
    }

    public static func normalizeCooldownMinutes(_ value: Int) -> Int {
        min(max(value, 1), 1_440)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case thresholdCharacters
        case accountPool
        case cooldownMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            thresholdCharacters: try container.decode(Int.self, forKey: .thresholdCharacters),
            accountPool: try container.decode([UUID].self, forKey: .accountPool),
            cooldownMinutes: try container.decode(Int.self, forKey: .cooldownMinutes)
        )
    }
}

public struct QuotaGuardRuntime: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var lastTargetAccountID: UUID?
    public var activeTransactionID: UUID?
    public var consecutiveFailures: Int
    public var lastSuccessAt: Date?

    public init(
        lastAttemptAt: Date? = nil,
        lastTargetAccountID: UUID? = nil,
        activeTransactionID: UUID? = nil,
        consecutiveFailures: Int = 0,
        lastSuccessAt: Date? = nil
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastTargetAccountID = lastTargetAccountID
        self.activeTransactionID = activeTransactionID
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.lastSuccessAt = lastSuccessAt
    }

    public mutating func recordAttempt(
        targetAccountID: UUID,
        transactionID: UUID? = nil,
        at date: Date
    ) {
        lastAttemptAt = date
        lastTargetAccountID = targetAccountID
        activeTransactionID = transactionID
    }

    public mutating func recordResult(succeeded: Bool, at date: Date) {
        if succeeded {
            consecutiveFailures = 0
            lastSuccessAt = date
        } else {
            consecutiveFailures = min(max(0, consecutiveFailures) + 1, 1_000)
        }
        activeTransactionID = nil
    }

    private enum CodingKeys: String, CodingKey {
        case lastAttemptAt
        case lastTargetAccountID
        case activeTransactionID
        case consecutiveFailures
        case lastSuccessAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            lastTargetAccountID: try container.decodeIfPresent(UUID.self, forKey: .lastTargetAccountID),
            activeTransactionID: try container.decodeIfPresent(UUID.self, forKey: .activeTransactionID),
            consecutiveFailures: try container.decode(Int.self, forKey: .consecutiveFailures),
            lastSuccessAt: try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        )
    }
}

public struct QuotaGuardDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var configuration: QuotaGuardConfiguration
    public var runtime: QuotaGuardRuntime

    public init(
        schemaVersion: Int = QuotaGuardDocument.currentSchemaVersion,
        configuration: QuotaGuardConfiguration = QuotaGuardConfiguration(),
        runtime: QuotaGuardRuntime = QuotaGuardRuntime()
    ) {
        self.schemaVersion = schemaVersion
        self.configuration = configuration
        self.runtime = runtime
    }
}

public enum QuotaGuardNoActionReason: String, Codable, Equatable, Sendable {
    case disabled
    case switchInProgress
    case typelessNotRunning
    case currentIdentityUnavailable
    case currentAccountUnmanaged
    case currentQuotaMissing
    case currentQuotaStale
    case activityRecording
    case activityProcessing
    case activityUnknown
    case poolAmbiguous
    case quotaSufficient
    case cooldown
    case noFreshTarget
}

public enum QuotaGuardDecision: Equatable, Sendable {
    case noAction(QuotaGuardNoActionReason)
    case trigger(UUID)
    case needsManualVerification(UUID)
}

public struct QuotaGuardInput: Sendable {
    public var configuration: QuotaGuardConfiguration
    public var runtime: QuotaGuardRuntime
    public var accounts: [AccountProfile]
    public var currentState: CurrentTypelessState?
    public var typelessRunning: Bool
    public var switchBusy: Bool
    public var now: Date
    public var maximumDataAge: TimeInterval

    public init(
        configuration: QuotaGuardConfiguration,
        runtime: QuotaGuardRuntime,
        accounts: [AccountProfile],
        currentState: CurrentTypelessState?,
        typelessRunning: Bool,
        switchBusy: Bool,
        now: Date,
        maximumDataAge: TimeInterval = 300
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.accounts = accounts
        self.currentState = currentState
        self.typelessRunning = typelessRunning
        self.switchBusy = switchBusy
        self.now = now
        self.maximumDataAge = maximumDataAge
    }
}

public enum QuotaGuardPolicy {
    public static func evaluate(_ input: QuotaGuardInput) -> QuotaGuardDecision {
        let configuration = input.configuration
        guard configuration.isEnabled else { return .noAction(.disabled) }
        guard !input.switchBusy else { return .noAction(.switchInProgress) }
        guard input.typelessRunning else { return .noAction(.typelessNotRunning) }
        guard let state = input.currentState, let currentEmail = state.email else {
            return .noAction(.currentIdentityUnavailable)
        }
        guard let current = input.accounts.first(where: { $0.email == currentEmail }) else {
            return .noAction(.currentAccountUnmanaged)
        }

        let pool = configuration.accountPool
        let poolSet = Set(pool)
        let accountsByID = Dictionary(uniqueKeysWithValues: input.accounts.map { ($0.id, $0) })
        guard pool.count >= 2,
              poolSet.count == pool.count,
              pool.contains(current.id),
              pool.allSatisfy({ accountsByID[$0] != nil })
        else {
            return .noAction(.poolAmbiguous)
        }

        guard let currentQuota = state.quota, currentQuota.limitCharacters > 0 else {
            return .noAction(.currentQuotaMissing)
        }
        guard currentQuota.isFresh(at: input.now, maximumAge: input.maximumDataAge) else {
            return .noAction(.currentQuotaStale)
        }
        switch state.activity {
        case .idle:
            break
        case .recording:
            return .noAction(.activityRecording)
        case .processing:
            return .noAction(.activityProcessing)
        case .unknown:
            break
        }

        let threshold = QuotaGuardConfiguration.normalizeThreshold(
            configuration.thresholdCharacters
        )
        guard currentQuota.remainingCharacters < threshold else {
            return .noAction(.quotaSufficient)
        }
        if let nextEligible = nextEligibleAt(
            configuration: configuration,
            runtime: input.runtime
        ), nextEligible > input.now {
            return .noAction(.cooldown)
        }

        guard let currentIndex = pool.firstIndex(of: current.id) else {
            return .noAction(.poolAmbiguous)
        }
        var unverifiedCandidate: UUID?
        for offset in 1 ..< pool.count {
            let candidateID = pool[(currentIndex + offset) % pool.count]
            guard let candidate = accountsByID[candidateID],
                  candidate.status == .available || candidate.status == .unknown else { continue }
            guard let quota = candidate.quota, quota.limitCharacters > 0,
                  quota.isFresh(at: input.now, maximumAge: input.maximumDataAge) else {
                if unverifiedCandidate == nil { unverifiedCandidate = candidateID }
                continue
            }
            guard quota.remainingCharacters > threshold else { continue }
            return state.activity == .idle && candidate.status == .available
                ? .trigger(candidate.id) : .needsManualVerification(candidate.id)
        }
        if let unverifiedCandidate { return .needsManualVerification(unverifiedCandidate) }
        return .noAction(.noFreshTarget)
    }

    public static func effectiveCooldown(
        configuration: QuotaGuardConfiguration,
        runtime: QuotaGuardRuntime
    ) -> TimeInterval {
        let base = TimeInterval(
            QuotaGuardConfiguration.normalizeCooldownMinutes(configuration.cooldownMinutes) * 60
        )
        let exponent = min(max(runtime.consecutiveFailures, 0), 5)
        let multiplier = TimeInterval(1 << exponent)
        return min(base * multiplier, 86_400)
    }

    public static func nextEligibleAt(
        configuration: QuotaGuardConfiguration,
        runtime: QuotaGuardRuntime
    ) -> Date? {
        runtime.lastAttemptAt?.addingTimeInterval(
            effectiveCooldown(configuration: configuration, runtime: runtime)
        )
    }
}
