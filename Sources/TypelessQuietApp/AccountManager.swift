import Combine
import Foundation
import TypelessQuietCore

enum AccountDiagnosticLevel: String, Codable {
    case success
    case warning
    case error
}

struct AccountDiagnosticItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let level: AccountDiagnosticLevel
}

protocol AccountDirectoryStoring: Sendable {
    var fileURL: URL { get }
    func load() throws -> AccountDirectory
    func save(_ directory: AccountDirectory) throws
}

extension AccountDirectoryStore: AccountDirectoryStoring {}

enum AccountManagerError: LocalizedError {
    case directoryUnavailable(String)
    case commitAndRollbackFailed(commit: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case let .directoryUnavailable(detail):
            "账号目录当前不可写：\(detail)；请先在诊断页处理加载错误"
        case let .commitAndRollbackFailed(commit, rollback):
            "账号数据保存失败（\(commit)），且 Keychain 恢复失败（\(rollback)）；请运行自检"
        }
    }
}

@MainActor
final class AccountManager: ObservableObject {
    @Published private(set) var directory: AccountDirectory
    @Published private(set) var currentState: CurrentTypelessState?
    @Published private(set) var currentReadResult: TypelessStateReadResult?
    @Published private(set) var diagnostics: [AccountDiagnosticItem] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRestartingTypeless = false
    @Published private(set) var clientControlMessage: String?
    @Published private(set) var message: String?

    private let directoryStore: any AccountDirectoryStoring
    private let secretStore: any AccountSecretStoring
    private let stateReader: any TypelessCurrentStateReading
    private let clientController: any TypelessClientControlling
    private var directoryLoadFailure: String?

    private enum SecretChange {
        case save(accountID: UUID, value: String)
        case delete(accountID: UUID)

        var accountID: UUID {
            switch self {
            case let .save(accountID, _), let .delete(accountID): accountID
            }
        }
    }

    convenience init() {
        self.init(
            directoryStore: Self.defaultDirectoryStore(),
            secretStore: KeychainAccountSecretStore(),
            stateReader: TypelessCurrentStateReader()
        )
    }

    init(
        directoryStore: any AccountDirectoryStoring,
        secretStore: any AccountSecretStoring,
        stateReader: any TypelessCurrentStateReading,
        clientController: (any TypelessClientControlling)? = nil
    ) {
        self.directoryStore = directoryStore
        self.secretStore = secretStore
        self.stateReader = stateReader
        self.clientController = clientController ?? TypelessClientController()
        do {
            directory = try directoryStore.load()
        } catch {
            directory = try! AccountDirectory()
            directoryLoadFailure = error.localizedDescription
            message = "账号目录加载失败：\(error.localizedDescription)"
        }
        do {
            try reconcileSecretFlags()
        } catch {
            message = "Keychain 状态同步失败：\(error.localizedDescription)"
        }
        refresh()
    }

    var accounts: [AccountProfile] { directory.accounts }

    var currentAccountIsManaged: Bool {
        guard let email = currentState?.email else { return false }
        return directory.account(matchingEmail: email) != nil
    }

    var menuSummary: String? {
        guard let state = currentState else { return nil }
        let identity = state.displayName.flatMap { $0.isEmpty ? nil : $0 }
            ?? state.email
            ?? "当前账号"
        if let quota = state.quota {
            guard quota.isFresh() else { return "\(identity)：额度已过期" }
            return "\(identity)：剩余 \(quota.remainingCharacters.formatted()) 字"
        }
        return "\(identity)：额度未知"
    }

    func openTypeless() {
        if !clientController.open() { clientControlMessage = TypelessClientControlError.unavailable.localizedDescription }
    }

    func restartTypeless() {
        guard !isRestartingTypeless else { return }
        refresh()
        guard let state = currentState, currentReadResult?.appRunning == true else {
            clientControlMessage = TypelessClientControlError.unavailable.localizedDescription
            return
        }
        guard state.activity != .recording, state.activity != .processing else {
            clientControlMessage = TypelessClientControlError.busy.localizedDescription
            return
        }
        isRestartingTypeless = true
        clientControlMessage = "正在请求 Typeless 正常退出并重新打开…"
        clientController.restart { [weak self] result in
            guard let self else { return }
            self.isRestartingTypeless = false
            switch result {
            case .success:
                self.clientControlMessage = "Typeless 已重新打开，请在设置 → 账户核对邮箱，再回主页。"
            case let .failure(error): self.clientControlMessage = error.localizedDescription
            }
            self.refresh()
        }
    }

    func addAccount(
        displayName: String,
        email: String,
        note: String,
        secret: String
    ) throws {
        var account = try AccountProfile(
            displayName: displayName,
            email: email,
            note: note,
            status: .unknown,
            hasSecret: !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        if let state = currentState,
           state.email == account.email {
            account.quota = state.quota
            if state.quota?.isFresh() == true { account.status = .available }
        }

        var candidate = directory
        try candidate.add(account)
        try commit(
            candidate,
            secretChange: account.hasSecret ? .save(accountID: account.id, value: secret) : nil
        )
        message = "已添加账号 \(account.displayName)"
        performSelfCheck()
    }

    func addCurrentAccount() throws {
        guard let state = currentState,
              let email = state.email,
              !currentAccountIsManaged
        else {
            return
        }
        var account = try AccountProfile(
            displayName: state.displayName ?? email,
            email: email,
            status: state.quota?.isFresh() == true ? .available : .unknown,
            quota: state.quota
        )
        account.updatedAt = Date()
        var candidate = directory
        try candidate.add(account)
        try commit(candidate)
        message = "已将当前 Typeless 账号加入管理"
        performSelfCheck()
    }

    func updateAccount(
        id: UUID,
        displayName: String,
        email: String,
        note: String,
        status: AccountStatus,
        autoSwitchEligible: Bool,
        newSecret: String?,
        clearSecret: Bool
    ) throws {
        guard let existing = directory.accounts.first(where: { $0.id == id }) else {
            throw AccountDirectoryError.accountNotFound
        }

        let identityChanged = AccountProfile.normalizedEmail(email) != existing.email
        let replacementSecret = newSecret.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let secretChange: SecretChange?
        let hasSecret: Bool
        if clearSecret || (identityChanged && replacementSecret == nil) {
            secretChange = .delete(accountID: id)
            hasSecret = false
        } else if let replacementSecret {
            secretChange = .save(accountID: id, value: replacementSecret)
            hasSecret = true
        } else {
            secretChange = nil
            hasSecret = existing.hasSecret
        }

        let retainedQuota = identityChanged ? nil : existing.quota
        let updated = try AccountProfile(
            id: id,
            displayName: displayName,
            email: email,
            note: note,
            status: status == .available && retainedQuota == nil ? .unknown : status,
            autoSwitchEligible: identityChanged ? false : autoSwitchEligible,
            quota: retainedQuota,
            hasSecret: hasSecret,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        var candidate = directory
        try candidate.update(updated)
        try commit(candidate, secretChange: secretChange)
        message = "已更新账号 \(updated.displayName)"
        performSelfCheck()
    }

    func setPaused(_ paused: Bool, accountID: UUID) throws {
        guard var account = directory.accounts.first(where: { $0.id == accountID }) else {
            throw AccountDirectoryError.accountNotFound
        }
        account.status = paused ? .paused : (account.quota == nil ? .unknown : .available)
        account.updatedAt = Date()
        var candidate = directory
        try candidate.update(account)
        try commit(candidate)
        performSelfCheck()
    }

    func removeAccount(id: UUID) throws {
        var copy = directory
        let removed = try copy.remove(id: id)
        try commit(copy, secretChange: .delete(accountID: id))
        message = "已删除账号 \(removed.displayName)"
        performSelfCheck()
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try stateReader.read()
            currentReadResult = result
            currentState = result.state
            message = nil
            do {
                try updateManagedQuota(from: result.state)
            } catch {
                message = "当前额度已读取，但账号目录更新失败：\(error.localizedDescription)"
            }
        } catch {
            currentReadResult = nil
            currentState = nil
            message = "Typeless 状态读取失败：\(error.localizedDescription)"
        }
        performSelfCheck(checkSecrets: false)
    }

    func performSelfCheck(checkSecrets: Bool = true) {
        var items: [AccountDiagnosticItem] = []
        let parent = directoryStore.fileURL.deletingLastPathComponent()
        if let directoryLoadFailure {
            items.append(AccountDiagnosticItem(
                id: "account-store",
                title: "账号目录加载失败",
                detail: directoryLoadFailure,
                level: .error
            ))
        } else {
            items.append(AccountDiagnosticItem(
                id: "account-store",
                title: "账号目录",
                detail: directory.accounts.isEmpty
                    ? "尚未添加账号；数据目录为 \(parent.path)"
                    : "schema v\(directory.schemaVersion)，\(directory.accounts.count) 个账号",
                level: .success
            ))
        }

        let cachedSecretChecks = diagnostics.filter { $0.id == "keychain" || $0.id.hasPrefix("secret-") }
        if !checkSecrets, !cachedSecretChecks.isEmpty {
            items.append(contentsOf: cachedSecretChecks)
        } else {
            do {
                for account in directory.accounts {
                    let actual = try secretStore.containsSecret(accountID: account.id)
                    if actual != account.hasSecret {
                        items.append(AccountDiagnosticItem(
                            id: "secret-\(account.id)",
                            title: "Keychain 状态不一致",
                            detail: "账号 \(account.displayName) 的秘密标记需要重新保存",
                            level: .warning
                        ))
                    }
                }
                if !items.contains(where: { $0.id.hasPrefix("secret-") }) {
                    items.append(AccountDiagnosticItem(
                        id: "keychain",
                        title: "Keychain",
                        detail: "按账号 UUID 隔离，未在账号 JSON 中保存秘密",
                        level: .success
                    ))
                }
            } catch {
                items.append(AccountDiagnosticItem(
                    id: "keychain",
                    title: "Keychain",
                    detail: error.localizedDescription,
                    level: .error
                ))
            }
        }

        if let result = currentReadResult {
            items.append(AccountDiagnosticItem(
                id: "typeless-storage",
                title: "Typeless 本地状态",
                detail: "只读：\(result.storageURL.path)",
                level: .success
            ))
            items.append(AccountDiagnosticItem(
                id: "typeless-runtime",
                title: "Typeless \(result.appVersion ?? "版本未知")",
                detail: result.appRunning ? "正在运行" : "未运行；可读取上次本地账号状态",
                level: result.appRunning ? .success : .warning
            ))
            items.append(AccountDiagnosticItem(
                id: "quota",
                title: "额度读取",
                detail: quotaDiagnosticDetail(
                    result.state.quota,
                    provenance: result.quotaProvenance
                ),
                level: quotaDiagnosticLevel(result.state.quota)
            ))
            items.append(AccountDiagnosticItem(
                id: "activity",
                title: "切换安全状态",
                detail: activityDiagnosticDetail(result.state.activity),
                level: result.state.activity == .idle ? .success : .warning
            ))
        } else {
            items.append(AccountDiagnosticItem(
                id: "typeless-storage",
                title: "Typeless 本地状态",
                detail: "未找到可读的 app-storage.json",
                level: .warning
            ))
        }
        diagnostics = items
    }

    func reportOperationFailure(_ context: String, error: Error) {
        message = "\(context)：\(error.localizedDescription)"
    }

    func replaceDirectoryForMigration(_ candidate: AccountDirectory) throws {
        try commit(candidate)
        message = nil
        performSelfCheck()
    }

    private func quotaDiagnosticDetail(
        _ quota: QuotaSnapshot?,
        provenance: TypelessQuotaReadProvenance
    ) -> String {
        if provenance == .requiresClientRestart {
            return "尚不能确认额度归属：首次读取、重新启动或同进程换号后，请停止录音并重启 Typeless，再核对账户"
        }
        if provenance == .awaitingIdentityConfirmation {
            return "请打开 Typeless 设置 → 账户核对邮箱，再回主页；核对前不将界面额度归到此账号"
        }
        guard let quota else {
            return "Typeless 官方主界面和白名单本地字段都未暴露额度，显示为未知"
        }
        let source = switch provenance {
        case .unavailable: "未知来源"
        case .awaitingIdentityConfirmation: "等待核对官方账号"
        case .requiresClientRestart: "等待重启 Typeless"
        case .localStorage: "Typeless 只读本地状态"
        case .visibleAccessibility: "Typeless 官方可见周额度"
        case .cachedAccessibility:
            "最近一次官方可见周额度（界面暂时被遮挡）"
        case .visibleWeeklyLimitReached:
            "Typeless 官方界面（每周限制已达）"
        }
        if quota.isFresh() {
            return "来自 \(source)，快照新鲜"
        }
        return "来自 \(source)，快照已过期"
    }

    private func quotaDiagnosticLevel(_ quota: QuotaSnapshot?) -> AccountDiagnosticLevel {
        guard let quota else { return .warning }
        return quota.isFresh() ? .success : .warning
    }

    private func activityDiagnosticDetail(_ activity: TypelessActivityState) -> String {
        switch activity {
        case .idle: "已读取到明确的空闲控件，可执行切换 preflight"
        case .recording: "Typeless 正在录音，禁止切换"
        case .processing: "Typeless 正在处理转录，禁止切换"
        case .unknown: "当前版本未暴露活动状态；可手动打开官方登录，自动切换暂停"
        }
    }

    private func updateManagedQuota(from state: CurrentTypelessState) throws {
        guard let email = state.email,
              let quota = state.quota,
              var account = directory.account(matchingEmail: email)
        else {
            return
        }
        let previous = account
        if let saved = account.quota, account.status != .unknown,
           saved.usedCharacters == quota.usedCharacters,
           saved.limitCharacters == quota.limitCharacters, saved.source == quota.source,
           saved.isFresh(at: quota.observedAt, maximumAge: 15) {
            return
        }
        account.quota = quota
        if account.status == .unknown, quota.isFresh() {
            account.status = .available
        }
        guard account != previous else { return }
        account.updatedAt = Date()
        var candidate = directory
        try candidate.update(account)
        try commit(candidate)
    }

    private func reconcileSecretFlags() throws {
        var updated = directory
        var changed = false
        for account in directory.accounts {
            let actual = try secretStore.containsSecret(accountID: account.id)
            guard actual != account.hasSecret else { continue }
            var reconciled = account
            reconciled.hasSecret = actual
            reconciled.updatedAt = Date()
            try updated.update(reconciled)
            changed = true
        }
        if changed {
            try commit(updated)
        }
    }

    private func commit(
        _ candidate: AccountDirectory,
        secretChange: SecretChange? = nil
    ) throws {
        if let directoryLoadFailure {
            throw AccountManagerError.directoryUnavailable(directoryLoadFailure)
        }
        let previousSecret: String?
        if let secretChange {
            previousSecret = try secretStore.readSecret(accountID: secretChange.accountID)
            switch secretChange {
            case let .save(accountID, value):
                try secretStore.saveSecret(value, accountID: accountID)
            case let .delete(accountID):
                try secretStore.deleteSecret(accountID: accountID)
            }
        } else {
            previousSecret = nil
        }

        do {
            try directoryStore.save(candidate)
        } catch {
            guard let secretChange else { throw error }
            do {
                if let previousSecret {
                    try secretStore.saveSecret(previousSecret, accountID: secretChange.accountID)
                } else {
                    try secretStore.deleteSecret(accountID: secretChange.accountID)
                }
            } catch let rollbackError {
                throw AccountManagerError.commitAndRollbackFailed(
                    commit: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
        directory = candidate
    }

    private static func defaultDirectoryStore() -> AccountDirectoryStore {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["TYPELESS_PLUSPLUS_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Typeless++", isDirectory: true)
        }
        return AccountDirectoryStore(fileURL: directory.appendingPathComponent("accounts.json"))
    }
}
