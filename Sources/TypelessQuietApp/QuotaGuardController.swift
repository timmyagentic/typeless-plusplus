import Combine
import Foundation
import TypelessQuietCore

protocol QuotaGuardStoring: Sendable {
    var fileURL: URL { get }
    func load() throws -> QuotaGuardDocument
    func save(_ document: QuotaGuardDocument) throws
}

enum QuotaGuardStoreError: LocalizedError, Equatable {
    case invalidSchema

    var errorDescription: String? {
        switch self {
        case .invalidSchema: "低额度守护数据版本不受支持"
        }
    }
}

struct QuotaGuardStore: QuotaGuardStoring {
    let fileURL: URL

    func load() throws -> QuotaGuardDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return QuotaGuardDocument()
        }
        let document = try JSONDecoder().decode(
            QuotaGuardDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard document.schemaVersion == QuotaGuardDocument.currentSchemaVersion else {
            throw QuotaGuardStoreError.invalidSchema
        }
        return document
    }

    func save(_ document: QuotaGuardDocument) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum QuotaGuardControllerError: LocalizedError, Equatable {
    case invalidPool
    case storageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidPool: "账号池至少需要两个不同且仍存在的账号"
        case let .storageUnavailable(detail): "守护配置不可写：\(detail)"
        }
    }
}

@MainActor
final class QuotaGuardController: ObservableObject {
    @Published private(set) var document: QuotaGuardDocument
    @Published private(set) var lastDecision: QuotaGuardDecision?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastSwitchOutcome: SwitchOutcome?
    @Published private(set) var storageError: String?
    @Published private(set) var configurationError: String?

    private let accountManager: AccountManager
    private let switchCoordinator: SwitchCoordinator
    private let store: any QuotaGuardStoring
    private let now: () -> Date
    private let monitoringInterval: TimeInterval
    private let timerEnabled: Bool
    private var timer: Timer?
    private var switchUpdates: AnyCancellable?
    private var activeGuardTransactionID: UUID?

    convenience init(
        accountManager: AccountManager,
        switchCoordinator: SwitchCoordinator
    ) {
        self.init(
            accountManager: accountManager,
            switchCoordinator: switchCoordinator,
            store: Self.defaultStore()
        )
    }

    init(
        accountManager: AccountManager,
        switchCoordinator: SwitchCoordinator,
        store: any QuotaGuardStoring,
        now: @escaping () -> Date = Date.init,
        monitoringInterval: TimeInterval = 60,
        timerEnabled: Bool = true
    ) {
        self.accountManager = accountManager
        self.switchCoordinator = switchCoordinator
        self.store = store
        self.now = now
        self.monitoringInterval = max(10, monitoringInterval)
        self.timerEnabled = timerEnabled
        do {
            document = try store.load()
        } catch {
            document = QuotaGuardDocument()
            storageError = error.localizedDescription
        }
        switchUpdates = switchCoordinator.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.reconcileSwitchOutcome()
            }
        }
        reconcilePersistedAttempt()
        updateTimer()
    }

    deinit {
        timer?.invalidate()
    }

    var configuration: QuotaGuardConfiguration { document.configuration }
    var runtime: QuotaGuardRuntime { document.runtime }
    var isMonitoring: Bool { timer != nil }
    var isSwitchBusy: Bool { switchCoordinator.isBusy }

    var nextEligibleAt: Date? {
        QuotaGuardPolicy.nextEligibleAt(
            configuration: document.configuration,
            runtime: document.runtime
        )
    }

    func setEnabled(_ enabled: Bool) throws {
        if let storageError {
            throw QuotaGuardControllerError.storageUnavailable(storageError)
        }
        if enabled {
            guard structurallyValidPool(document.configuration.accountPool) else {
                configurationError = QuotaGuardControllerError.invalidPool.localizedDescription
                throw QuotaGuardControllerError.invalidPool
            }
        }
        var copy = document
        copy.configuration.isEnabled = enabled
        try commit(copy)
        configurationError = nil
        updateTimer()
        if !enabled {
            lastDecision = .noAction(.disabled)
        }
    }

    func setThreshold(_ value: Int) throws {
        var copy = document
        copy.configuration.thresholdCharacters = QuotaGuardConfiguration.normalizeThreshold(value)
        try commit(copy)
    }

    func setCooldownMinutes(_ value: Int) throws {
        var copy = document
        copy.configuration.cooldownMinutes = QuotaGuardConfiguration.normalizeCooldownMinutes(value)
        try commit(copy)
    }

    func setAccountPool(_ accountIDs: [UUID]) throws {
        var copy = document
        copy.configuration.accountPool = accountIDs
        if copy.configuration.isEnabled, !structurallyValidPool(accountIDs) {
            copy.configuration.isEnabled = false
            lastDecision = .noAction(.poolAmbiguous)
            configurationError = QuotaGuardControllerError.invalidPool.localizedDescription
        } else {
            configurationError = nil
        }
        try commit(copy)
        updateTimer()
    }

    func movePoolAccount(fromOffsets: IndexSet, toOffset: Int) throws {
        var pool = document.configuration.accountPool
        pool.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try setAccountPool(pool)
    }

    func movePoolAccount(id: UUID, offset: Int) throws {
        var pool = document.configuration.accountPool
        guard let index = pool.firstIndex(of: id) else { return }
        let destination = index + offset
        guard pool.indices.contains(destination) else { return }
        pool.swapAt(index, destination)
        try setAccountPool(pool)
    }

    func applyMigrationDocument(_ candidate: QuotaGuardDocument) throws {
        guard candidate.schemaVersion == QuotaGuardDocument.currentSchemaVersion else {
            throw QuotaGuardStoreError.invalidSchema
        }
        var safe = candidate
        safe.configuration.isEnabled = false
        safe.runtime = QuotaGuardRuntime()
        try commit(safe)
        lastDecision = .noAction(.disabled)
        lastSwitchOutcome = nil
        configurationError = nil
        updateTimer()
    }

    func restoreDocumentAfterMigrationFailure(_ candidate: QuotaGuardDocument) throws {
        guard candidate.schemaVersion == QuotaGuardDocument.currentSchemaVersion else {
            throw QuotaGuardStoreError.invalidSchema
        }
        try commit(candidate)
        updateTimer()
    }

    func evaluateNow() {
        guard storageError == nil else { return }
        lastSwitchOutcome = nil
        accountManager.refresh()
        // A visible quota receives its timestamp during refresh. Evaluate afterwards
        // so a genuinely new observation is not rejected as coming from the future.
        let checkedAt = now()
        lastCheckedAt = checkedAt
        let result = accountManager.currentReadResult
        let decision = QuotaGuardPolicy.evaluate(QuotaGuardInput(
            configuration: document.configuration,
            runtime: document.runtime,
            accounts: accountManager.accounts,
            currentState: result?.state,
            typelessRunning: result?.appRunning ?? false,
            switchBusy: switchCoordinator.isBusy,
            now: checkedAt
        ))
        lastDecision = decision
        guard case let .trigger(targetAccountID) = decision else { return }

        beginAttempt(targetAccountID: targetAccountID, source: .quotaGuard, checkedAt: checkedAt)
    }

    var recommendedAccountID: UUID? {
        guard case let .needsManualVerification(id) = lastDecision else { return nil }
        return id
    }

    func startRecommendedSwitch() {
        // Re-check current identity, busy state, pool and cooldown at the user's click.
        evaluateNow()
        guard !switchCoordinator.isBusy, let target = recommendedAccountID else { return }
        beginAttempt(targetAccountID: target, source: .manual, checkedAt: now())
    }

    func snoozeRecommendation() {
        guard let target = recommendedAccountID else { return }
        var copy = document
        copy.runtime.lastAttemptAt = now()
        copy.runtime.lastTargetAccountID = target
        do {
            try commit(copy)
            lastDecision = .noAction(.cooldown)
        } catch { return }
    }

    private func beginAttempt(targetAccountID: UUID, source: SwitchSource, checkedAt: Date) {
        var attempted = document
        attempted.runtime.recordAttempt(targetAccountID: targetAccountID, at: checkedAt)
        do {
            try commit(attempted)
        } catch {
            return
        }

        switchCoordinator.startSwitch(to: targetAccountID, source: source)
        guard let operation = switchCoordinator.operation,
              operation.targetAccountID == targetAccountID,
              operation.source == source
        else {
            recordAttemptResult(succeeded: false, at: now())
            return
        }
        activeGuardTransactionID = operation.id
        var withTransaction = document
        withTransaction.runtime.activeTransactionID = operation.id
        try? commit(withTransaction)
        reconcileSwitchOutcome()
    }

    func reconcileSwitchOutcome() {
        let transactionID = activeGuardTransactionID ?? document.runtime.activeTransactionID
        guard let transactionID,
              let operation = switchCoordinator.operation,
              operation.id == transactionID,
              !switchCoordinator.isBusy,
              let outcome = operation.outcome
        else {
            return
        }
        lastSwitchOutcome = outcome
        recordAttemptResult(succeeded: outcome == .succeeded, at: now())
        activeGuardTransactionID = nil
    }

    private func recordAttemptResult(succeeded: Bool, at date: Date) {
        var copy = document
        copy.runtime.recordResult(succeeded: succeeded, at: date)
        try? commit(copy)
    }

    private func commit(_ candidate: QuotaGuardDocument) throws {
        do {
            try store.save(candidate)
            document = candidate
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            timer?.invalidate()
            timer = nil
            document.configuration.isEnabled = false
            throw error
        }
    }

    private func structurallyValidPool(_ accountIDs: [UUID]) -> Bool {
        let known = Set(accountManager.accounts.map(\.id))
        return accountIDs.count >= 2
            && Set(accountIDs).count == accountIDs.count
            && accountIDs.allSatisfy(known.contains)
    }

    private func reconcilePersistedAttempt() {
        guard let transactionID = document.runtime.activeTransactionID else { return }
        if switchCoordinator.operation?.id == transactionID {
            activeGuardTransactionID = transactionID
            reconcileSwitchOutcome()
            return
        }
        recordAttemptResult(succeeded: false, at: now())
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard timerEnabled,
              storageError == nil,
              document.configuration.isEnabled
        else {
            return
        }
        let timer = Timer(timeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateNow()
            }
        }
        timer.tolerance = min(5, monitoringInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func defaultStore() -> QuotaGuardStore {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["TYPELESS_PLUSPLUS_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Typeless++", isDirectory: true)
        }
        return QuotaGuardStore(fileURL: directory.appendingPathComponent("quota-guard.json"))
    }
}
