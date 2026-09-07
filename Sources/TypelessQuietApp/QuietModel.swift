import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import TypelessQuietCore

@MainActor
final class QuietModel: ObservableObject {
    let updater: UpdaterController
    let accountManager: AccountManager
    let switchCoordinator: SwitchCoordinator
    let quotaGuardController: QuotaGuardController
    let backupController: BackupController
    @Published private(set) var isEnabled: Bool
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var typelessRunning = false
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var lastDismissal: Date?
    @Published private(set) var issueText: String?

    private let defaults = UserDefaults.standard
    // Preserve legacy defaults keys across the Typeless++ rename.
    private let enabledDefaultsKey = "TypelessQuietEnabled"
    private let accessibilityPromptedBuildKey = "InitialSetup.AccessibilityPromptedBuild.v2"
    private let launchAtLoginInitializedKey = "InitialSetup.LaunchAtLogin.v1"
    private let initialSetupPolicy = InitialSetupPolicy()
    private var permissionTimer: Timer?
    private var accountStateMonitor: TypelessStateMonitor?
    private var accountUpdates: AnyCancellable?
    private var switchUpdates: AnyCancellable?
    private var quotaGuardUpdates: AnyCancellable?
    private var backupUpdates: AnyCancellable?
    private var updaterUpdates: AnyCancellable?

    private lazy var mainWindow = MainWindowController(model: self)

    private lazy var accessibilityOnboarding = AccessibilityOnboardingController(
        openSettings: { [weak self] in
            self?.requestAccessibility()
        }
    )

    private lazy var monitor = TypelessMonitor { [weak self] event in
        self?.handleMonitorEvent(event)
    }

    init(
        accountManager: AccountManager? = nil,
        switchCoordinator: SwitchCoordinator? = nil,
        quotaGuardController: QuotaGuardController? = nil,
        backupController: BackupController? = nil
    ) {
        let resolvedAccountManager = accountManager ?? AccountManager()
        let resolvedSwitchCoordinator = switchCoordinator
            ?? SwitchCoordinator(accountManager: resolvedAccountManager)
        let resolvedQuotaGuardController = quotaGuardController
            ?? QuotaGuardController(
                accountManager: resolvedAccountManager,
                switchCoordinator: resolvedSwitchCoordinator
            )
        let resolvedBackupController = backupController
            ?? BackupController(
                accountManager: resolvedAccountManager,
                quotaGuardController: resolvedQuotaGuardController,
                switchCoordinator: resolvedSwitchCoordinator
            )
        updater = UpdaterController()
        self.accountManager = resolvedAccountManager
        self.switchCoordinator = resolvedSwitchCoordinator
        self.quotaGuardController = resolvedQuotaGuardController
        self.backupController = resolvedBackupController
        if defaults.object(forKey: enabledDefaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: enabledDefaultsKey)
        }

        accessibilityGranted = AXIsProcessTrusted()
        refreshLaunchAtLoginStatus()
        performInitialSetup()
        let stateMonitor = TypelessStateMonitor(
            storageURL: resolvedAccountManager.currentReadResult?.storageURL
                ?? TypelessCurrentStateReader.storageCandidates[0]
        ) { [weak resolvedAccountManager] in
            resolvedAccountManager?.refresh()
        }
        accountStateMonitor = stateMonitor
        stateMonitor.start()
        monitor.start()
        monitor.setWatchingAllowed(isEnabled && accessibilityGranted)

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityStatus()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        accountUpdates = resolvedAccountManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        switchUpdates = resolvedSwitchCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        quotaGuardUpdates = resolvedQuotaGuardController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        updaterUpdates = updater.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        backupUpdates = resolvedBackupController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var statusText: String {
        if !isEnabled {
            return "已暂停"
        }
        if !accessibilityGranted {
            return "需要辅助功能权限"
        }
        if typelessRunning {
            return "正在监听 Typeless"
        }
        return "等待 Typeless 启动"
    }

    var statusSymbol: String {
        if quotaGuardController.recommendedAccountID != nil {
            return "person.crop.circle.badge.exclamationmark"
        }
        if issueText != nil {
            return "exclamationmark.triangle.fill"
        }
        if !isEnabled {
            return "pause.circle"
        }
        if accessibilityGranted {
            return "bell.slash.fill"
        }
        return "lock.fill"
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledDefaultsKey)
        issueText = nil
        monitor.setWatchingAllowed(enabled && accessibilityGranted)
    }

    func requestAccessibility() {
        accessibilityOnboarding.show()
        promptForAccessibility()
        openAccessibilitySettings()
    }

    func showAccessibilityOnboarding() {
        accessibilityOnboarding.show()
    }

    func showPrimaryInterface() {
        if accessibilityGranted {
            accountManager.refresh()
            mainWindow.show()
        } else {
            accessibilityOnboarding.show()
        }
    }

    private func promptForAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        defaults.set(true, forKey: launchAtLoginInitializedKey)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            issueText = nil
        } catch {
            issueText = "无法更新登录项：\(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refreshAccessibilityStatus() {
        let current = AXIsProcessTrusted()
        guard current != accessibilityGranted else { return }
        accessibilityGranted = current
        issueText = nil
        monitor.setWatchingAllowed(isEnabled && current)
        if current {
            accessibilityOnboarding.close()
            mainWindow.show()
        } else {
            mainWindow.close()
            accessibilityOnboarding.show()
        }
    }

    private func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled
        launchAtLoginRequiresApproval = status == .requiresApproval
    }

    private func performInitialSetup() {
        let plan = initialSetupPolicy.plan(for: InitialSetupState(
            accessibilityGranted: accessibilityGranted,
            accessibilityPromptedBuild: defaults.string(
                forKey: accessibilityPromptedBuildKey
            ),
            currentBuild: currentBuild,
            launchAtLoginInitialized: defaults.bool(forKey: launchAtLoginInitializedKey),
            launchAtLoginStatus: launchAtLoginSetupStatus
        ))

        if plan.presentAccessibilityOnboarding {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.accessibilityOnboarding.show()
                if plan.promptForAccessibility {
                    await Task.yield()
                    self?.promptForAccessibility()
                }
            }
        }
        if plan.recordAccessibilityPromptBuild {
            defaults.set(currentBuild, forKey: accessibilityPromptedBuildKey)
        }

        if plan.markLaunchAtLoginInitialized {
            defaults.set(true, forKey: launchAtLoginInitializedKey)
        } else if plan.registerLaunchAtLogin {
            do {
                try SMAppService.mainApp.register()
                defaults.set(true, forKey: launchAtLoginInitializedKey)
            } catch {
                issueText = "无法默认启用登录时启动：\(error.localizedDescription)"
            }
        }

        refreshLaunchAtLoginStatus()
    }

    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
    }

    private var launchAtLoginSetupStatus: LaunchAtLoginSetupStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    private func handleMonitorEvent(_ event: TypelessMonitorEvent) {
        switch event {
        case let .runningChanged(running):
            typelessRunning = running
        case let .dismissed(date):
            lastDismissal = date
            issueText = nil
        case let .unsafe(message):
            issueText = "规则已安全跳过：\(message)"
        case let .error(message):
            issueText = message
        }
    }
}
