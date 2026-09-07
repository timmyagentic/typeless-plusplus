import AppKit
import Combine
import Foundation
import TypelessQuietCore

struct BackupImportPreview: Equatable {
    let accountCount: Int
    let addedCount: Int
    let updatedCount: Int
    let remappedIDCount: Int
    let reauthenticationCount: Int
    let guardWasEnabled: Bool
}

enum BackupControllerError: LocalizedError, Equatable {
    case switchInProgress
    case importAndRollbackFailed(importError: String, rollbackError: String)

    var errorDescription: String? {
        switch self {
        case .switchInProgress:
            "切换或恢复进行中，暂不能导入"
        case let .importAndRollbackFailed(importError, rollbackError):
            "导入失败（\(importError)），且本地回滚失败（\(rollbackError)）"
        }
    }
}

@MainActor
final class BackupController: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var lastPreview: BackupImportPreview?
    @Published private(set) var lastExportURL: URL?

    private let accountManager: AccountManager
    private let quotaGuardController: QuotaGuardController
    private let switchCoordinator: SwitchCoordinator
    private let loginOpener: any OfficialTypelessLoginOpening
    private let appVersion: () -> String

    convenience init(
        accountManager: AccountManager,
        quotaGuardController: QuotaGuardController,
        switchCoordinator: SwitchCoordinator
    ) {
        self.init(
            accountManager: accountManager,
            quotaGuardController: quotaGuardController,
            switchCoordinator: switchCoordinator,
            loginOpener: OfficialTypelessLoginOpener()
        )
    }

    init(
        accountManager: AccountManager,
        quotaGuardController: QuotaGuardController,
        switchCoordinator: SwitchCoordinator,
        loginOpener: any OfficialTypelessLoginOpening,
        appVersion: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown"
        }
    ) {
        self.accountManager = accountManager
        self.quotaGuardController = quotaGuardController
        self.switchCoordinator = switchCoordinator
        self.loginOpener = loginOpener
        self.appVersion = appVersion
    }

    var accountsRequiringOfficialLogin: [AccountProfile] {
        accountManager.accounts.filter { $0.status == .unknown }
    }

    var officialLoginURL: URL { loginOpener.loginURL }

    func exportData(exportedAt: Date = Date()) throws -> Data {
        let backup = try PortableBackupCodec.makeBackup(
            directory: accountManager.directory,
            quotaGuard: quotaGuardController.configuration,
            appVersion: appVersion(),
            exportedAt: exportedAt
        )
        return try PortableBackupCodec.encode(backup)
    }

    func export(to fileURL: URL, exportedAt: Date = Date()) throws {
        let data = try exportData(exportedAt: exportedAt)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        lastExportURL = fileURL
        message = "已导出无秘密备份：\(fileURL.lastPathComponent)"
    }

    func previewImport(_ data: Data) throws -> BackupImportPreview {
        let backup = try PortableBackupCodec.decode(data)
        let plan = try BackupMigrationPlanner.plan(
            backup: backup,
            existing: accountManager.directory
        )
        let preview = BackupImportPreview(
            accountCount: backup.accounts.count,
            addedCount: plan.addedCount,
            updatedCount: plan.updatedCount,
            remappedIDCount: plan.remappedIDCount,
            reauthenticationCount: plan.requiresOfficialReauthentication.count,
            guardWasEnabled: backup.quotaGuard.wasEnabled
        )
        lastPreview = preview
        return preview
    }

    @discardableResult
    func importData(_ data: Data, now: Date = Date()) throws -> BackupImportPreview {
        guard !switchCoordinator.isBusy else {
            throw BackupControllerError.switchInProgress
        }
        let backup = try PortableBackupCodec.decode(data)
        let plan = try BackupMigrationPlanner.plan(
            backup: backup,
            existing: accountManager.directory,
            now: now
        )
        let previousDirectory = accountManager.directory
        let previousGuard = quotaGuardController.document

        try accountManager.replaceDirectoryForMigration(plan.directory)
        do {
            try quotaGuardController.applyMigrationDocument(plan.quotaGuard)
        } catch {
            let importError = error
            var rollbackErrors: [String] = []
            do {
                try accountManager.replaceDirectoryForMigration(previousDirectory)
            } catch {
                rollbackErrors.append("账号目录：\(error.localizedDescription)")
            }
            do {
                try quotaGuardController.restoreDocumentAfterMigrationFailure(previousGuard)
            } catch {
                rollbackErrors.append("守护配置：\(error.localizedDescription)")
            }
            if !rollbackErrors.isEmpty {
                throw BackupControllerError.importAndRollbackFailed(
                    importError: importError.localizedDescription,
                    rollbackError: rollbackErrors.joined(separator: "；")
                )
            }
            throw importError
        }

        let preview = BackupImportPreview(
            accountCount: backup.accounts.count,
            addedCount: plan.addedCount,
            updatedCount: plan.updatedCount,
            remappedIDCount: plan.remappedIDCount,
            reauthenticationCount: plan.requiresOfficialReauthentication.count,
            guardWasEnabled: backup.quotaGuard.wasEnabled
        )
        lastPreview = preview
        message = "已合并 \(preview.accountCount) 个账号；守护保持关闭"
        if preview.reauthenticationCount > 0 {
            message? += "，\(preview.reauthenticationCount) 个新账号需要官方登录验证"
        }
        return preview
    }

    func importFile(_ fileURL: URL) throws -> BackupImportPreview {
        try importData(Data(contentsOf: fileURL))
    }

    func openOfficialLogin() -> Bool {
        loginOpener.openLogin()
    }

    func refreshReauthenticationStatus() {
        accountManager.refresh()
        let remaining = accountsRequiringOfficialLogin.count
        message = remaining == 0
            ? "所有导入账号都已在本机验证"
            : "仍有 \(remaining) 个账号需要通过官方登录验证"
    }
}
