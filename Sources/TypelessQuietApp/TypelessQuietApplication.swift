import SwiftUI

@main
enum TypelessBootstrap {
    static func main() {
        if UpdaterController.isIsolatedQA(.main) {
            TypelessUpdaterQAApplication.main()
        } else {
            TypelessQuietApplication.main()
        }
    }
}

struct TypelessQuietApplication: App {
    @NSApplicationDelegateAdaptor(TypelessQuietAppDelegate.self)
    private var appDelegate
    @StateObject private var model: QuietModel

    init() {
        let model = QuietModel()
        _model = StateObject(wrappedValue: model)
        MainWindowRequestRouter.handler = { [weak model] in
            model?.showPrimaryInterface()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(model.statusText)

            if let accountSummary = model.accountManager.menuSummary {
                Text(accountSummary)
            }

            if let operation = model.switchCoordinator.operation {
                Text(operation.menuSummary(accounts: model.accountManager.accounts))
            }

            Text(model.quotaGuardController.menuSummary)
            if model.quotaGuardController.recommendedAccountID != nil {
                Button("登录验证备用账号") { model.quotaGuardController.startRecommendedSwitch() }
                Button("稍后提醒") { model.quotaGuardController.snoozeRecommendation() }
            }

            if let lastDismissal = model.lastDismissal {
                Text("上次关闭：\(lastDismissal.formatted(date: .abbreviated, time: .standard))")
            }

            if let issueText = model.issueText {
                Text(issueText)
            }

            Divider()

            Button("刷新账号与额度") {
                model.accountManager.refresh(forceOfficialQuota: true)
            }

            let switchableAccounts = model.accountManager.accounts.filter {
                ($0.status == .available || $0.status == .unknown) && $0.email != model.accountManager.currentState?.email
            }
            if !switchableAccounts.isEmpty {
                Menu("安全切换账号") {
                    ForEach(switchableAccounts) { account in
                        Button(account.displayName) {
                            model.switchCoordinator.startSwitch(to: account.id)
                        }
                        .disabled(model.switchCoordinator.isBusy)
                    }
                }
            }

            if model.switchCoordinator.isBusy {
                Button("取消切换并恢复") {
                    model.switchCoordinator.cancelAndRestore()
                }
            }

            Toggle(
                "低额度守护",
                isOn: Binding(
                    get: { model.quotaGuardController.configuration.isEnabled },
                    set: { try? model.quotaGuardController.setEnabled($0) }
                )
            )

            if model.quotaGuardController.configuration.isEnabled {
                Button("立即检查低额度") {
                    model.quotaGuardController.evaluateNow()
                }
            }

            Divider()

            Button("打开 Typeless++") {
                model.showPrimaryInterface()
            }

            Divider()

            Toggle(
                "启用自动关闭",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            )

            if model.accessibilityGranted {
                Label("辅助功能权限已授予", systemImage: "checkmark.shield")
            } else {
                Button("显示授权引导…") {
                    model.showAccessibilityOnboarding()
                }
                Button("打开辅助功能设置") {
                    model.openAccessibilitySettings()
                }
            }

            Toggle(
                "登录时启动",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                )
            )

            if model.launchAtLoginRequiresApproval {
                Label("登录项等待系统设置批准", systemImage: "exclamationmark.circle")
            }

            Button("打开登录项设置") {
                model.openLoginItemSettings()
            }

            Divider()

            UpdateMenu(updater: model.updater)

            Divider()

            Button("退出 Typeless++") {
                model.quit()
            }
        } label: {
            Label("Typeless++", systemImage: model.updater.hasUpdate ? "arrow.down.circle.fill" : model.statusSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Only a separately identified QA bundle may run the updater without connecting
/// to Typeless, the account stores, Accessibility or login-item registration.
private struct TypelessUpdaterQAApplication: App {
    @NSApplicationDelegateAdaptor(TypelessQuietAppDelegate.self) private var appDelegate
    @StateObject private var updater: UpdaterController

    var body: some Scene {
        MenuBarExtra("Typeless++ Update QA", systemImage: "arrow.down.circle") {
            UpdateMenu(updater: updater)
            Button("退出 QA") { NSApplication.shared.terminate(nil) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("打开更新") { updater.present() }
            }
        }
    }

    init() {
        let updater = UpdaterController()
        _updater = StateObject(wrappedValue: updater)
        MainWindowRequestRouter.handler = { [weak updater] in updater?.present() }
    }
}
