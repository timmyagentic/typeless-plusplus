import SwiftUI
import TypelessQuietCore

struct QuotaGuardSection: View {
    @ObservedObject var manager: AccountManager
    @ObservedObject var switchCoordinator: SwitchCoordinator
    @ObservedObject var controller: QuotaGuardController
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("低额度守护").font(.title3.weight(.semibold))
                    Text("默认关闭；只复用官方登录、验证和恢复流程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "启用",
                    isOn: Binding(
                        get: { controller.configuration.isEnabled },
                        set: setEnabled
                    )
                )
                .toggleStyle(.switch)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("规则").font(.headline)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("剩余低于")
                                TextField("字数", value: Binding(
                                    get: { controller.configuration.thresholdCharacters },
                                    set: { value in update { try controller.setThreshold(value) } }
                                ), format: .number.grouping(.never))
                                .accessibilityLabel("低额度阈值（字）")
                                .frame(width: 80)
                                Text("字时检查切换")
                            }
                            HStack {
                                Text("基础冷却")
                                TextField("分钟", value: Binding(
                                    get: { controller.configuration.cooldownMinutes },
                                    set: { value in update { try controller.setCooldownMinutes(value) } }
                                ), format: .number.grouping(.never))
                                .accessibilityLabel("基础冷却（分钟）")
                                .frame(width: 80)
                                Text("分钟")
                            }
                            Text("失败会指数延长冷却，最多 24 小时；成功后清零失败计数。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("有序账号池").font(.headline)
                        VStack(alignment: .leading, spacing: 10) {
                            if controller.configuration.accountPool.isEmpty {
                                Text("尚未选择账号")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(controller.configuration.accountPool.enumerated()), id: \.offset) { index, id in
                                HStack(spacing: 10) {
                                    Text("#\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account(id)?.displayName ?? "已删除账号")
                                        Text(accountStatus(id))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        update { try controller.movePoolAccount(id: id, offset: -1) }
                                    } label: {
                                        Image(systemName: "arrow.up")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0)
                                    .accessibilityLabel("提高优先级")
                                    Button {
                                        update { try controller.movePoolAccount(id: id, offset: 1) }
                                    } label: {
                                        Image(systemName: "arrow.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == controller.configuration.accountPool.count - 1)
                                    .accessibilityLabel("降低优先级")
                                    Button(role: .destructive) {
                                        update {
                                            try controller.setAccountPool(
                                                controller.configuration.accountPool.filter { $0 != id }
                                            )
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("移出账号池")
                                }
                            }

                            Menu {
                                let available = manager.accounts.filter {
                                    !controller.configuration.accountPool.contains($0.id)
                                }
                                if available.isEmpty {
                                    Text("没有可添加账号")
                                } else {
                                    ForEach(available) { account in
                                        Button(account.displayName) {
                                            update {
                                                try controller.setAccountPool(
                                                    controller.configuration.accountPool + [account.id]
                                                )
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("添加账号", systemImage: "plus")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("当前状态").font(.headline)
                        VStack(alignment: .leading, spacing: 10) {
                            Label(controller.menuSummary, systemImage: statusSymbol)
                            if let id = controller.recommendedAccountID {
                                Text("当前额度偏低。备用账号额度或活动状态尚未确认，请在停止录音后手动登录验证；旧快照不会被视为最新余额。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("登录验证 \(account(id)?.displayName ?? "备用账号")") {
                                    controller.startRecommendedSwitch()
                                }
                                .disabled(switchCoordinator.isBusy)
                                Button("稍后提醒") { controller.snoozeRecommendation() }
                            }
                            if let lastCheckedAt = controller.lastCheckedAt {
                                Text("上次检查：\(lastCheckedAt.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let nextEligibleAt = controller.nextEligibleAt,
                               nextEligibleAt > Date() {
                                Text("下次最早尝试：\(nextEligibleAt.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("连续失败：\(controller.runtime.consecutiveFailures)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("立即检查") {
                                controller.evaluateNow()
                            }
                            .disabled(!controller.configuration.isEnabled || switchCoordinator.isBusy)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .cardStyle()


                    Text("触发时可能打开 Typeless 官方登录页，需要你在官网选择账号；Typeless++ 不会自动填写密码，也不会静默注入会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = localError ?? controller.configurationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
    }

    private var statusSymbol: String {
        if controller.storageError != nil { return "xmark.octagon.fill" }
        if !controller.configuration.isEnabled { return "pause.circle" }
        if switchCoordinator.isBusy { return "arrow.triangle.2.circlepath" }
        return "shield.checkered"
    }

    private func setEnabled(_ enabled: Bool) {
        update { try controller.setEnabled(enabled) }
    }

    private func update(_ action: () throws -> Void) {
        do {
            try action()
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func account(_ id: UUID) -> AccountProfile? {
        manager.accounts.first { $0.id == id }
    }

    private func accountStatus(_ id: UUID) -> String {
        guard let account = account(id) else { return "账号不存在，守护会 fail closed" }
        switch account.status {
        case .unknown: return "待登录验证"
        case .paused: return "已暂停"
        case .exhausted: return "额度用尽"
        case .available: break
        }
        guard let quota = account.quota else { return "额度未知" }
        return quota.isFresh()
            ? "剩余 \(quota.remainingCharacters.formatted()) 字 · 快照新鲜"
            : "额度快照已过期"
    }
}

extension QuotaGuardController {
    var menuSummary: String {
        if storageError != nil { return "额度守护：配置不可用" }
        if configurationError != nil { return "额度守护：账号池无效" }
        guard configuration.isEnabled else { return "额度守护：已关闭" }
        if isSwitchBusy { return "额度守护：切换进行中" }
        if let lastSwitchOutcome {
            switch lastSwitchOutcome {
            case .succeeded: return "额度守护：上次切换已验证"
            case .originalPreserved: return "额度守护：原账号已保留"
            case .originalRestored: return "额度守护：原账号已恢复"
            case .verificationRequired: return "额度守护：登录结果待核对"
            case .recoveryRequired: return "额度守护：仍需恢复原账号"
            case .cancelled: return "额度守护：已停止跟踪上次切换"
            }
        }
        guard let lastDecision else { return "额度守护：等待首次检查" }
        switch lastDecision {
        case let .noAction(reason): return "额度守护：\(reason.userMessage)"
        case .trigger: return "额度守护：已触发安全切换"
        case .needsManualVerification: return "额度守护：建议手动登录验证备用账号"
        }
    }
}

extension QuotaGuardNoActionReason {
    var userMessage: String {
        switch self {
        case .disabled: "已关闭"
        case .switchInProgress: "已有切换进行中"
        case .typelessNotRunning: "Typeless 未运行"
        case .currentIdentityUnavailable: "当前账号不可读"
        case .currentAccountUnmanaged: "当前账号未加入管理"
        case .currentQuotaMissing: "当前额度未知"
        case .currentQuotaStale: "当前额度已过期"
        case .activityRecording: "录音中，未切换"
        case .activityProcessing: "转录处理中，未切换"
        case .activityUnknown: "无法证明空闲，未切换"
        case .poolAmbiguous: "账号池存在歧义"
        case .quotaSufficient: "当前额度充足"
        case .cooldown: "冷却中"
        case .noFreshTarget: "没有新鲜且额度充足的目标"
        }
    }
}
