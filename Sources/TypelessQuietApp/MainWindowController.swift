import AppKit
import SwiftUI

private struct MainWindowSnapshot {
    let statusText: String
    let statusSymbol: String
    let isEnabled: Bool
    let accessibilityGranted: Bool
    let typelessRunning: Bool
    let launchAtLoginEnabled: Bool
    let launchAtLoginRequiresApproval: Bool
    let lastDismissalText: String?
    let issueText: String?

    @MainActor
    init(model: QuietModel) {
        statusText = model.statusText
        statusSymbol = model.statusSymbol
        isEnabled = model.isEnabled
        accessibilityGranted = model.accessibilityGranted
        typelessRunning = model.typelessRunning
        launchAtLoginEnabled = model.launchAtLoginEnabled
        launchAtLoginRequiresApproval = model.launchAtLoginRequiresApproval
        lastDismissalText = model.lastDismissal?.formatted(
            date: .abbreviated,
            time: .standard
        )
        issueText = model.issueText
    }
}

@MainActor
final class MainWindowController {
    private let model: QuietModel
    private let accountManager: AccountManager
    private var window: NSWindow?

    init(model: QuietModel) {
        self.model = model
        accountManager = model.accountManager
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: MainWindowView(
            model: model,
            accountManager: accountManager
        ))

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Typeless++"
        window.identifier = NSUserInterfaceItemIdentifier("MainWindow")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        // Keep the legacy autosave key so existing users retain their window placement.
        window.setFrameAutosaveName("TypelessQuietMainWindow")
        window.center()
        return window
    }
}

private struct MainWindowView: View {
    @ObservedObject var model: QuietModel
    @ObservedObject var accountManager: AccountManager
    @State private var selectedSection = MainWindowSection.overview

    var body: some View {
        let snapshot = MainWindowSnapshot(model: model)
        VStack(spacing: 0) {
            header(snapshot)

            Divider()

            Picker("页面", selection: $selectedSection) {
                ForEach(MainWindowSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch selectedSection {
                case .overview:
                    overview(snapshot)
                case .accounts:
                    AccountListSection(
                        manager: accountManager,
                        switchCoordinator: model.switchCoordinator
                    )
                case .quotaGuard:
                    QuotaGuardSection(
                        manager: accountManager,
                        switchCoordinator: model.switchCoordinator,
                        controller: model.quotaGuardController
                    )
                case .migration:
                    BackupMigrationSection(
                        manager: accountManager,
                        controller: model.backupController
                    )
                case .diagnostics:
                    AccountDiagnosticsSection(
                        manager: accountManager,
                        switchCoordinator: model.switchCoordinator,
                        guardController: model.quotaGuardController
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text("关闭窗口后，Typeless++ 仍会在菜单栏运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                UpdateBadge(updater: model.updater)
                Button("退出", action: model.quit)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 720, height: 620)
    }

    private func overview(_ snapshot: MainWindowSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                CurrentAccountCard(manager: accountManager)
                SwitchStatusCard(
                    manager: accountManager,
                    coordinator: model.switchCoordinator
                )
                automaticDismissCard(snapshot)
                systemAccessCard(snapshot)

                if let issueText = snapshot.issueText {
                    Label(issueText, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(20)
        }
    }

    private func header(_ snapshot: MainWindowSnapshot) -> some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Typeless++")
                    .font(.system(size: 24, weight: .semibold))

                Label(snapshot.statusText, systemImage: snapshot.statusSymbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor(snapshot))

                if let lastDismissalText = snapshot.lastDismissalText {
                    Text("上次关闭：\(lastDismissalText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private func automaticDismissCard(_ snapshot: MainWindowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "自动关闭升级提示",
                isOn: Binding(get: { snapshot.isEnabled }, set: model.setEnabled)
            )
            .toggleStyle(.switch)
            .font(.headline)

            Text("自动兼容 Typeless 2.4.0 与旧版瞬时升级提示；常驻订阅卡片和规则有歧义时不会点击。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func systemAccessCard(_ snapshot: MainWindowSnapshot) -> some View {
        VStack(spacing: 14) {
            HStack {
                Label("设备控制权限", systemImage: "checkmark.shield")
                    .font(.headline)

                Spacer()

                if snapshot.accessibilityGranted {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button("设置…", action: model.requestAccessibility)
                }
            }

            Divider()

            HStack {
                Label("登录时启动", systemImage: "arrow.clockwise")
                    .font(.headline)

                Spacer()

                Toggle(
                    "登录时启动",
                    isOn: Binding(
                        get: { snapshot.launchAtLoginEnabled },
                        set: model.setLaunchAtLogin
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if snapshot.launchAtLoginRequiresApproval {
                HStack {
                    Label("登录项等待系统批准", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)

                    Spacer()

                    Button("打开系统设置", action: model.openLoginItemSettings)
                }
            }
        }
        .cardStyle()
    }

    private func statusColor(_ snapshot: MainWindowSnapshot) -> Color {
        if snapshot.issueText != nil || !snapshot.accessibilityGranted {
            return .orange
        }
        if !snapshot.isEnabled {
            return .secondary
        }
        return snapshot.typelessRunning ? .green : .secondary
    }
}

extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
