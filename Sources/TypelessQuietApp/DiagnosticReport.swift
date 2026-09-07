import Foundation
import TypelessQuietCore

/// An allowlisted support report, built independently of account/backup serialization.
/// No free-form diagnostic messages, identities, URLs, UUIDs or quota values are copied.
struct DiagnosticReport: Codable, Equatable {
    struct Versions: Codable, Equatable {
        let application: String
        let build: String
        let macOS: String
        let typeless: String
    }

    enum QuotaStatus: String, Codable {
        case unavailable, fresh, stale
    }

    struct Client: Codable, Equatable {
        let running: Bool?
        let identityReadable: Bool
        let activity: TypelessActivityState
        let quotaStatus: QuotaStatus
        let quotaProvenance: TypelessQuotaReadProvenance
    }

    struct Accounts: Codable, Equatable {
        let total: Int
        let paused: Int
        let awaitingVerification: Int
    }

    struct Check: Codable, Equatable {
        enum Code: String, Codable, CaseIterable {
            case accountStore, keychain, secretFlagMismatch, typelessStorage, typelessRuntime, quota, activity
        }
        let code: Code
        let level: AccountDiagnosticLevel
    }

    struct SwitchEvent: Codable, Equatable {
        let source: SwitchSource
        let phase: SwitchPhase
        let outcome: SwitchOutcome?
        let failureCode: SwitchFailureCode?
    }

    let schemaVersion: Int
    let generatedAt: Date
    let versions: Versions
    let accessibilityGranted: Bool
    let client: Client
    let accounts: Accounts
    let checks: [Check]
    let recentSwitchEvents: [SwitchEvent]
    let auditAvailable: Bool
    let guardEnabled: Bool

    init(
        applicationVersion: String?, buildVersion: String?, macOSVersion: String?,
        readResult: TypelessStateReadResult?, accounts: [AccountProfile],
        diagnostics: [AccountDiagnosticItem], auditEvents: [SwitchAuditEvent],
        auditAvailable: Bool, accessibilityGranted: Bool, guardEnabled: Bool,
        now: Date = Date()
    ) {
        schemaVersion = 1
        generatedAt = now
        versions = Versions(application: Self.numericVersion(applicationVersion),
            build: Self.numericVersion(buildVersion), macOS: Self.numericVersion(macOSVersion),
            typeless: Self.numericVersion(readResult?.appVersion))
        self.accessibilityGranted = accessibilityGranted
        client = Client(running: readResult?.appRunning,
            identityReadable: readResult?.state.email != nil,
            activity: readResult?.state.activity ?? .unknown,
            quotaStatus: readResult?.state.quota.map { $0.isFresh(at: now) ? .fresh : .stale } ?? .unavailable,
            quotaProvenance: readResult?.quotaProvenance ?? .unavailable)
        self.accounts = Accounts(total: accounts.count,
            paused: accounts.filter { $0.status == .paused }.count,
            awaitingVerification: accounts.filter { $0.status == .unknown || $0.quota == nil }.count)
        // Multiple per-account Keychain warnings collapse into one anonymous check.
        var levels: [Check.Code: AccountDiagnosticLevel] = [:]
        for item in diagnostics {
            let code: Check.Code
            switch item.id {
            case "account-store": code = .accountStore
            case "keychain": code = .keychain
            case "typeless-storage": code = .typelessStorage
            case "typeless-runtime": code = .typelessRuntime
            case "quota": code = .quota
            case "activity": code = .activity
            case let id where id.hasPrefix("secret-"): code = .secretFlagMismatch
            default: continue
            }
            if let previous = levels[code], Self.severity(previous) >= Self.severity(item.level) { continue }
            levels[code] = item.level
        }
        checks = Check.Code.allCases.compactMap { code in
            levels[code].map { Check(code: code, level: $0) }
        }
        recentSwitchEvents = auditEvents.suffix(20).map {
            SwitchEvent(source: $0.source, phase: $0.phase, outcome: $0.outcome, failureCode: $0.failureCode)
        }
        self.auditAvailable = auditAvailable
        self.guardEnabled = guardEnabled
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func numericVersion(_ value: String?) -> String {
        guard let value, value.range(of: #"\A[0-9]{1,4}(\.[0-9]{1,4}){0,3}\z"#,
                                    options: .regularExpression) != nil else { return "unknown" }
        return value
    }

    private static func severity(_ level: AccountDiagnosticLevel) -> Int {
        switch level { case .success: 0; case .warning: 1; case .error: 2 }
    }
}
