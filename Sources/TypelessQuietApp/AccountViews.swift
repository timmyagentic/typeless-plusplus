import AppKit
import ApplicationServices
import SwiftUI
import TypelessQuietCore
import UniformTypeIdentifiers

enum MainWindowSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case accounts = "账号"
    case quotaGuard = "守护"
    case migration = "迁移"
    case diagnostics = "诊断"

    var id: String { rawValue }
}

struct CurrentAccountCard: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("当前 Typeless 账号", systemImage: "person.crop.circle")
                    .font(.headline)
                Spacer()
                if manager.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("刷新") { manager.refresh() }
                }
            }

            if let state = manager.currentState {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.displayName.flatMap { $0.isEmpty ? nil : $0 }
                            ?? state.email
                            ?? "未登录")
                            .font(.title3.weight(.semibold))
                        if let email = state.email {
                            Text(email).font(.callout).foregroundStyle(.secondary)
                        }
                        if let plan = state.planName, !plan.isEmpty {
                            Text(plan).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let quota = state.quota {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("剩余 \(quota.remainingCharacters.formatted()) 字")
                                .font(.headline)
                            Text("已用 \(quota.usedCharacters.formatted()) / \(quota.limitCharacters.formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(quota.isFresh()
                                ? "同步于 \(quota.observedAt.formatted(date: .omitted, time: .shortened))"
                                : "快照已过期")
                                .font(.caption2)
                                .foregroundStyle(quota.isFresh() ? Color.secondary : Color.orange)
                        }
                    } else {
                        Text("额度未知")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }

                if let quota = state.quota, quota.limitCharacters > 0 {
                    ProgressView(
                        value: Double(quota.usedCharacters),
                        total: Double(quota.limitCharacters)
                    )
                }

                TypelessQuotaGuidance(manager: manager)
                if state.email != nil && !manager.currentAccountIsManaged {
                    Button("添加当前账号") {
                        do {
                            try manager.addCurrentAccount()
                        } catch {
                            manager.reportOperationFailure("添加当前账号失败", error: error)
                            manager.performSelfCheck()
                        }
                    }
                }
            } else {
                Text("尚未读取到 Typeless 登录状态")
                    .foregroundStyle(.secondary)
                if let message = manager.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .cardStyle()
    }
}

struct TypelessQuotaGuidance: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        if manager.currentReadResult?.quotaProvenance == .requiresClientRestart {
            VStack(alignment: .leading, spacing: 8) {
                Text("需要刷新 Typeless 登录状态").font(.callout.weight(.semibold))
                Text("尚不能确认主页额度属于当前账号。请结束录音，再重启 Typeless；随后打开设置 → 账户核对邮箱，回到主页即可自动同步。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(manager.isRestartingTypeless ? "正在重启…" : "录音结束后重启 Typeless") {
                    manager.restartTypeless()
                }
                .disabled(manager.isRestartingTypeless)
                if let message = manager.clientControlMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if manager.currentReadResult?.quotaProvenance == .awaitingIdentityConfirmation {
            VStack(alignment: .leading, spacing: 6) {
                Text("请打开 Typeless 设置 → 账户核对邮箱，再回主页。完成后额度会自动同步。")
                    .font(.caption).foregroundStyle(.orange)
                Button("打开 Typeless 核对账户") { manager.openTypeless() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountListSection: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var switchCoordinator: SwitchCoordinator
    @State private var editor: AccountEditorDraft?
    @State private var pendingDelete: AccountProfile?
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已有账号").font(.title3.weight(.semibold))
                    Text("通过官网登录；未识别活动状态时，请先停止录音再切换")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editor = AccountEditorDraft()
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .disabled(switchCoordinator.isBusy)
            }

            SwitchStatusCard(manager: manager, coordinator: switchCoordinator)
            TypelessQuotaGuidance(manager: manager)

            if manager.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("尚未添加账号").font(.headline)
                    Text("添加你已经拥有的 Typeless 账号；本阶段不会注册新账号。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.accounts) { account in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(account.displayName).font(.headline)
                                        if manager.currentState?.email == account.email {
                                            Text("当前")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.14))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(account.email).font(.caption).foregroundStyle(.secondary)
                                    HStack(spacing: 8) {
                                        Text(account.quota == nil && account.status == .available ? "尚未验证" : account.status.displayName)
                                        Text(account.hasSecret ? "Keychain 已保存" : "无秘密")
                                        if let quota = account.quota {
                                            Text(quota.isFresh()
                                                ? "剩余 \(quota.remainingCharacters.formatted())"
                                                : "额度快照已过期")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle(
                                    "启用",
                                    isOn: Binding(
                                        get: { account.status != .paused },
                                        set: { enabled in
                                            do {
                                                try manager.setPaused(!enabled, accountID: account.id)
                                                localError = nil
                                            } catch {
                                                localError = error.localizedDescription
                                            }
                                        }
                                    )
                                )
                                .labelsHidden()
                                .disabled(switchCoordinator.isBusy)
                                if manager.currentState?.email != account.email {
                                    Button(account.status == .unknown ? "登录验证" : "切换") {
                                        switchCoordinator.startSwitch(to: account.id)
                                    }
                                    .disabled(![.available, .unknown].contains(account.status) || switchCoordinator.isBusy)
                                }
                                Button {
                                    editor = AccountEditorDraft(account: account)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("编辑 \(account.displayName)")
                                .disabled(switchCoordinator.isBusy)
                                Button(role: .destructive) {
                                    pendingDelete = account
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("删除 \(account.displayName)")
                                .disabled(switchCoordinator.isBusy)
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .contain)
                            Divider()
                        }
                    }
                    .padding(12)
                }
            }

            if let localError {
                Text(localError).font(.caption).foregroundStyle(.red)
            } else if let message = manager.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .sheet(item: $editor) { draft in
            AccountEditorView(
                manager: manager,
                switchCoordinator: switchCoordinator,
                draft: draft
            )
        }
        .alert(item: $pendingDelete) { account in
            Alert(
                title: Text("删除 \(account.displayName)？"),
                message: Text("账号元数据和对应 Keychain 秘密将从 Typeless++ 删除，不会修改 Typeless。"),
                primaryButton: .destructive(Text("删除")) {
                    guard !switchCoordinator.isBusy else {
                        localError = "切换进行中，账号目录已锁定"
                        return
                    }
                    do {
                        try manager.removeAccount(id: account.id)
                        localError = nil
                    } catch {
                        localError = error.localizedDescription
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

struct SwitchStatusCard: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var coordinator: SwitchCoordinator

    var body: some View {
        if let operation = coordinator.operation {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if coordinator.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: operation.outcome == .succeeded
                            ? "checkmark.circle.fill"
                            : "arrow.triangle.2.circlepath.circle")
                            .foregroundStyle(operation.outcome == .succeeded ? .green : .orange)
                    }
                    Text(title(for: operation)).font(.headline)
                    Spacer()
                }

                Text(detail(for: operation))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if coordinator.isBusy {
                        Button(operation.phase == .restoring
                            ? "重新打开恢复页面"
                            : "重新打开官方登录") {
                            coordinator.reopenOfficialLogin()
                        }
                        Button("停止跟踪") { coordinator.stopTracking() }
                        if operation.phase != .restoring {
                            Button("取消并恢复") {
                                coordinator.cancelAndRestore()
                            }
                        }
                    } else {
                        if coordinator.canResumeVerification {
                            Button("继续验证当前账号") { coordinator.resumeVerification() }
                        }
                        if coordinator.canRecoverTerminalOperation {
                            Button("打开官方恢复页") {
                                coordinator.recoverTerminalOperation()
                            }
                        }
                        Button("关闭提示") {
                            coordinator.dismissTerminalOperation()
                        }
                    }
                }

                if let auditError = coordinator.auditError {
                    Label(
                        "切换审计不可用：\(auditError)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
            .cardStyle()
        }
    }

    private func title(for operation: SwitchOperation) -> String {
        let target = accountName(operation.targetAccountID)
        let original = operation.originalAccountID.map(accountName) ?? "原账号"
        switch operation.phase {
        case .preflight: return "正在检查是否可以切换"
        case .requestingSwitch: return "正在打开 Typeless 官方登录"
        case .verifying: return "正在验证 \(target)"
        case .restoring: return "正在恢复 \(original)"
        case .succeeded: return "已安全切换到 \(target)"
        case .failed:
            switch operation.outcome {
            case .originalPreserved: return "未切换，\(original) 已保留"
            case .originalRestored: return "切换未完成，已恢复 \(original)"
            case .verificationRequired: return "登录结果待核对"
            case .recoveryRequired: return "需要恢复 \(original)"
            case .cancelled: return "已停止跟踪"
            case .succeeded: return "已安全切换到 \(target)"
            case nil: return "切换未完成"
            }
        }
    }

    private func detail(for operation: SwitchOperation) -> String {
        let target = accountName(operation.targetAccountID)
        let original = operation.originalAccountID.map(accountName) ?? "原账号"
        switch operation.phase {
        case .preflight:
            return "正在核对账号并检查活动状态。自动守护还要求新鲜额度与明确空闲证据。"
        case .requestingSwitch:
            return "Typeless++ 只打开官网，不读取或保存登录链接中的认证信息。"
        case .verifying:
            let targetEmail = manager.accounts.first { $0.id == operation.targetAccountID }?.email ?? target
            if manager.currentState?.email == targetEmail {
                return "已读取到目标邮箱 \(targetEmail)。请按下方提示核对额度，完成后自动确认成功。"
            }
            return "请在官方页面选择或登录 \(targetEmail)。完成桌面交接后会自动读取身份；每次换号需重启 Typeless 并在账户页核对邮箱，再回主页读取额度。"
        case .restoring:
            return "官方恢复页已打开，请登录“\(original)”；验证原邮箱和新鲜额度后才算恢复完成。"
        case .succeeded:
            return "目标邮箱和新鲜额度均已从 Typeless 官方界面确认。"
        case .failed:
            if operation.outcome == .originalRestored {
                return "已通过 Typeless 官方界面重新确认原邮箱和新鲜额度，恢复完成。"
            }
            if operation.outcome == .cancelled {
                return "已停止跟踪。官网尚未完成的登录仍可能生效，请关闭不用的登录页。"
            }
            return operation.failureCode?.userMessage ?? "切换没有完成。"
        }
    }

    private func accountName(_ id: UUID) -> String {
        manager.accounts.first(where: { $0.id == id })?.displayName ?? "账号"
    }
}

struct AccountDiagnosticsSection: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var switchCoordinator: SwitchCoordinator
    @ObservedObject var guardController: QuotaGuardController
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("账号与额度自检").font(.title3.weight(.semibold))
                    Text("不会显示或记录密码、token、Cookie、验证码或设备 ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导出脱敏诊断…") { exportDiagnostics() }
                Button("重新检查") {
                    manager.refresh()
                    manager.performSelfCheck()
                }
            }

            Text("导出仅含版本、能力状态、账号数量和固定错误码，不含邮箱、路径、备注、额度数值或转录内容。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let exportMessage {
                Text(exportMessage).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }

            List {
                Section("环境") {
                    ForEach(manager.diagnostics) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.level.symbolName)
                                .foregroundStyle(item.level.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("最近切换") {
                    if switchCoordinator.auditEvents.isEmpty {
                        Text("暂无切换记录")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(switchCoordinator.auditEvents.suffix(20).reversed())) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.phase.displayName).font(.headline)
                                    Spacer()
                                    Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(auditDetail(event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "typeless-plusplus-diagnostics.json"
        panel.message = "保存脱敏诊断。仅保存在你选择的位置，不会自动上传。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let report = DiagnosticReport(
            applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            readResult: manager.currentReadResult, accounts: manager.accounts, diagnostics: manager.diagnostics,
            auditEvents: switchCoordinator.auditEvents, auditAvailable: switchCoordinator.auditError == nil,
            accessibilityGranted: AXIsProcessTrusted(), guardEnabled: guardController.configuration.isEnabled)
        do {
            try report.write(to: url)
            exportMessage = "已保存脱敏诊断，可自行检查后分享。"
        } catch {
            exportMessage = "诊断保存失败，请检查所选目录的写入权限后重试。"
        }
    }

    private func auditDetail(_ event: SwitchAuditEvent) -> String {
        let target = manager.accounts.first(where: { $0.id == event.targetAccountID })?.displayName
            ?? "已删除账号"
        if let outcome = event.outcome {
            let result = outcome.displayName
            if let failure = event.failureCode {
                return "目标：\(target) · \(result) · \(failure.userMessage)"
            }
            return "目标：\(target) · \(result)"
        }
        return "目标：\(target) · 进行中"
    }
}

struct AccountEditorDraft: Identifiable {
    let id = UUID()
    let accountID: UUID?
    var displayName: String
    var email: String
    var note: String
    var status: AccountStatus
    var autoSwitchEligible: Bool
    var hasExistingSecret: Bool

    init(account: AccountProfile? = nil) {
        accountID = account?.id
        displayName = account?.displayName ?? ""
        email = account?.email ?? ""
        note = account?.note ?? ""
        status = account?.status ?? .unknown
        autoSwitchEligible = account?.autoSwitchEligible ?? false
        hasExistingSecret = account?.hasSecret ?? false
    }
}

private struct AccountEditorView: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var switchCoordinator: SwitchCoordinator
    let draft: AccountEditorDraft
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var email: String
    @State private var note: String
    @State private var status: AccountStatus
    @State private var autoSwitchEligible: Bool
    @State private var secret = ""
    @State private var clearSecret = false
    @State private var errorText: String?

    init(
        manager: AccountManager,
        switchCoordinator: SwitchCoordinator,
        draft: AccountEditorDraft
    ) {
        self.manager = manager
        self.switchCoordinator = switchCoordinator
        self.draft = draft
        _displayName = State(initialValue: draft.displayName)
        _email = State(initialValue: draft.email)
        _note = State(initialValue: draft.note)
        _status = State(initialValue: draft.status)
        _autoSwitchEligible = State(initialValue: draft.autoSwitchEligible)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.accountID == nil ? "添加已有账号" : "编辑账号")
                .font(.title2.weight(.semibold))

            Form {
                TextField("显示名称", text: $displayName)
                TextField("邮箱", text: $email)
                TextField("备注", text: $note)
                Picker("状态", selection: $status) {
                    ForEach(AccountStatus.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                Text("低额度守护的账号选择在“守护”页配置。")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField(
                    draft.hasExistingSecret ? "新密码（留空则保持现有）" : "密码（可选）",
                    text: $secret
                )
                if draft.hasExistingSecret {
                    Toggle("清除已保存的 Keychain 秘密", isOn: $clearSecret)
                }
            }
            .formStyle(.grouped)

            Text("Typeless++ 不会把密码写入账号 JSON，也不会读取或保存 Typeless token/Cookie。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(switchCoordinator.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save() {
        guard !switchCoordinator.isBusy else {
            errorText = "切换进行中，账号目录已锁定"
            return
        }
        do {
            if let accountID = draft.accountID {
                try manager.updateAccount(
                    id: accountID,
                    displayName: displayName,
                    email: email,
                    note: note,
                    status: status,
                    autoSwitchEligible: autoSwitchEligible,
                    newSecret: secret.isEmpty ? nil : secret,
                    clearSecret: clearSecret
                )
            } else {
                try manager.addAccount(
                    displayName: displayName,
                    email: email,
                    note: note,
                    secret: secret
                )
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private extension AccountStatus {
    var displayName: String {
        switch self {
        case .available: "已启用"
        case .paused: "已暂停"
        case .exhausted: "额度用尽"
        case .unknown: "待登录验证"
        }
    }
}

private extension AccountDiagnosticLevel {
    var symbolName: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

extension SwitchOperation {
    func menuSummary(accounts: [AccountProfile]) -> String {
        let target = accounts.first(where: { $0.id == targetAccountID })?.displayName ?? "目标账号"
        switch phase {
        case .preflight: return "切换：安全检查中"
        case .requestingSwitch: return "切换：正在打开官网"
        case .verifying: return "切换：正在验证 \(target)"
        case .restoring: return "切换：正在恢复原账号"
        case .succeeded: return "切换：\(target) 已验证"
        case .failed: return "切换：未完成"
        }
    }
}

private extension SwitchFailureCode {
    var userMessage: String {
        switch self {
        case .transactionInProgress: "已有切换正在进行。"
        case .targetNotFound: "目标账号已不存在，请刷新账号列表。"
        case .targetNotAvailable: "目标账号已暂停或标记为额度用尽。"
        case .alreadyCurrent: "目标账号就是当前账号。"
        case .typelessNotRunning: "Typeless 未运行；打开 Typeless 后再试。"
        case .currentAccountUnreadable: "当前 Typeless 账号不可读，已安全停止。"
        case .currentAccountUnmanaged: "请先把当前 Typeless 账号加入管理，才能保留回滚目标。"
        case .currentQuotaMissing: "当前额度未知，无法建立可验证的切换基线。"
        case .currentQuotaStale: "当前额度快照已过期，请刷新后重试。"
        case .activityRecording: "Typeless 正在录音，已禁止切换。"
        case .activityProcessing: "Typeless 正在处理转录，已禁止切换。"
        case .activityUnknown: "无法证明 Typeless 已空闲，已安全停止。"
        case .officialLoginOpenFailed: "未能打开 Typeless 官方登录页，原账号未改动。"
        case .verificationTimedOut: "在时限内没有验证到目标邮箱和新鲜额度，请核对当前官方账号。"
        case .verificationObservedDifferentAccount: "Typeless 显示了非目标账号，已启动官方恢复。"
        case .verificationQuotaMissingOrStale: "已看到目标邮箱，额度仍待核对。请刷新官方客户端后继续验证，或选择恢复原账号。"
        case .originalStateUnverified: "仍看到原邮箱，额度尚未核对；请在官方客户端确认后重试。"
        case .cancelled: "用户已取消本次切换。"
        case .rollbackOpenFailed: "未能打开官方恢复页，请点击重新打开并登录原账号。"
        case .rollbackTimedOut: "尚未验证原账号恢复，请重新打开官方页面继续恢复。"
        case .auditWriteFailed: "切换审计不可写，验证已停止；请检查诊断后重试。"
        case .interrupted: "上次切换被应用退出中断，没有自动继续。"
        }
    }
}

private extension SwitchPhase {
    var displayName: String {
        switch self {
        case .preflight: "Preflight"
        case .requestingSwitch: "打开官方登录"
        case .verifying: "验证目标账号"
        case .succeeded: "切换成功"
        case .failed: "切换结束"
        case .restoring: "恢复原账号"
        }
    }
}

private extension SwitchOutcome {
    var displayName: String {
        switch self {
        case .succeeded: "成功"
        case .originalPreserved: "原账号已保留"
        case .originalRestored: "原账号已恢复"
        case .verificationRequired: "登录结果待核对"
        case .recoveryRequired: "仍需恢复"
        case .cancelled: "已取消"
        }
    }
}
