import Foundation

public enum AccountDirectoryError: String, Error, Equatable, Sendable, LocalizedError {
    case duplicateEmail
    case invalidEmail
    case invalidSchema
    case accountNotFound

    public var errorDescription: String? {
        switch self {
        case .duplicateEmail: "该邮箱已经存在"
        case .invalidEmail: "请输入有效邮箱"
        case .invalidSchema: "账号数据版本不受支持"
        case .accountNotFound: "账号不存在"
        }
    }
}

public enum AccountStatus: String, Codable, CaseIterable, Sendable {
    case available
    case paused
    case exhausted
    case unknown
}

public enum QuotaSource: String, Codable, Sendable {
    case typelessAccessibility
    case typelessLocalStorage
    case typelessOfficialAPI
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public static let defaultMaximumAge: TimeInterval = 300

    public var usedCharacters: Int
    public var limitCharacters: Int
    public var observedAt: Date
    public var source: QuotaSource

    public init(
        usedCharacters: Int,
        limitCharacters: Int,
        observedAt: Date,
        source: QuotaSource
    ) {
        self.usedCharacters = max(0, usedCharacters)
        self.limitCharacters = max(0, limitCharacters)
        self.observedAt = observedAt
        self.source = source
    }

    public var remainingCharacters: Int {
        max(0, limitCharacters - usedCharacters)
    }

    public func isFresh(at date: Date = Date(), maximumAge: TimeInterval = Self.defaultMaximumAge) -> Bool {
        let age = date.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumAge
    }

    private enum CodingKeys: String, CodingKey {
        case usedCharacters
        case limitCharacters
        case observedAt
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            usedCharacters: try container.decode(Int.self, forKey: .usedCharacters),
            limitCharacters: try container.decode(Int.self, forKey: .limitCharacters),
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            source: try container.decode(QuotaSource.self, forKey: .source)
        )
    }
}

public struct AccountProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var email: String
    public var note: String
    public var status: AccountStatus
    public var autoSwitchEligible: Bool
    public var quota: QuotaSnapshot?
    public var hasSecret: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        email: String,
        note: String = "",
        status: AccountStatus = .available,
        autoSwitchEligible: Bool = false,
        quota: QuotaSnapshot? = nil,
        hasSecret: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard let normalizedEmail = Self.normalizedEmail(email) else {
            throw AccountDirectoryError.invalidEmail
        }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = id
        self.displayName = normalizedName.isEmpty ? normalizedEmail : normalizedName
        self.email = normalizedEmail
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
        self.autoSwitchEligible = autoSwitchEligible
        self.quota = quota
        self.hasSecret = hasSecret
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func normalizedEmail(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".")
        else {
            return nil
        }
        return normalized
    }
}

public struct AccountDirectory: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var accounts: [AccountProfile]

    public init(
        schemaVersion: Int = AccountDirectory.currentSchemaVersion,
        accounts: [AccountProfile] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AccountDirectoryError.invalidSchema
        }
        var seen = Set<String>()
        var normalizedAccounts: [AccountProfile] = []
        for account in accounts {
            let normalized = try Self.normalized(account)
            guard seen.insert(normalized.email).inserted else {
                throw AccountDirectoryError.duplicateEmail
            }
            normalizedAccounts.append(normalized)
        }
        self.schemaVersion = schemaVersion
        self.accounts = normalizedAccounts
        sortAccounts()
    }

    public mutating func add(_ account: AccountProfile) throws {
        let normalized = try Self.normalized(account)
        guard !accounts.contains(where: { $0.email == normalized.email }) else {
            throw AccountDirectoryError.duplicateEmail
        }
        accounts.append(normalized)
        sortAccounts()
    }

    public mutating func update(_ account: AccountProfile) throws {
        let normalized = try Self.normalized(account)
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            throw AccountDirectoryError.accountNotFound
        }
        guard !accounts.contains(where: {
            $0.id != normalized.id && $0.email == normalized.email
        }) else {
            throw AccountDirectoryError.duplicateEmail
        }
        accounts[index] = normalized
        sortAccounts()
    }

    @discardableResult
    public mutating func remove(id: UUID) throws -> AccountProfile {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountDirectoryError.accountNotFound
        }
        return accounts.remove(at: index)
    }

    public func account(matchingEmail email: String) -> AccountProfile? {
        guard let normalized = AccountProfile.normalizedEmail(email) else { return nil }
        return accounts.first { $0.email == normalized }
    }

    private mutating func sortAccounts() {
        accounts.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func normalized(_ account: AccountProfile) throws -> AccountProfile {
        try AccountProfile(
            id: account.id,
            displayName: account.displayName,
            email: account.email,
            note: account.note,
            status: account.status,
            autoSwitchEligible: account.autoSwitchEligible,
            quota: account.quota,
            hasSecret: account.hasSecret,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }
}

public struct AccountDirectoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> AccountDirectory {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return try AccountDirectory()
        }
        let decoded = try JSONDecoder().decode(AccountDirectory.self, from: Data(contentsOf: fileURL))
        return try AccountDirectory(schemaVersion: decoded.schemaVersion, accounts: decoded.accounts)
    }

    public func save(_ directory: AccountDirectory) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(directory)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public struct CurrentTypelessState: Codable, Equatable, Sendable {
    public var email: String?
    public var displayName: String?
    public var planName: String?
    public var quota: QuotaSnapshot?
    public var observedAt: Date
    public var sourceModifiedAt: Date?
    public var activity: TypelessActivityState

    public init(
        email: String?,
        displayName: String?,
        planName: String?,
        quota: QuotaSnapshot?,
        observedAt: Date,
        sourceModifiedAt: Date?,
        activity: TypelessActivityState = .unknown
    ) {
        self.email = email.flatMap(AccountProfile.normalizedEmail)
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planName = planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.quota = quota
        self.observedAt = observedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.activity = activity
    }

    public func merging(quota: QuotaSnapshot?) -> CurrentTypelessState {
        var copy = self
        if let quota {
            copy.quota = quota
            copy.observedAt = max(observedAt, quota.observedAt)
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case planName
        case quota
        case observedAt
        case sourceModifiedAt
        case activity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            email: try container.decodeIfPresent(String.self, forKey: .email),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            planName: try container.decodeIfPresent(String.self, forKey: .planName),
            quota: try container.decodeIfPresent(QuotaSnapshot.self, forKey: .quota),
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            sourceModifiedAt: try container.decodeIfPresent(Date.self, forKey: .sourceModifiedAt),
            activity: try container.decodeIfPresent(TypelessActivityState.self, forKey: .activity)
                ?? .unknown
        )
    }
}

public enum TypelessLocalStateParser {
    private struct Storage: Decodable {
        let userData: UserData?
        let quotaUsage: QuotaUsage?
    }

    private struct UserData: Decodable {
        let email: String?
        let name: String?
        let subscriptionPlanName: String?

        enum CodingKeys: String, CodingKey {
            case email
            case name
            case subscriptionPlanName = "subscription_plan_name"
        }
    }

    private struct QuotaUsage: Decodable {
        let used: Int?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case used
            case current
            case usedCharacters
            case limit
            case total
            case limitCharacters
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try container.decodeIfPresent(Int.self, forKey: .used)
                ?? container.decodeIfPresent(Int.self, forKey: .current)
                ?? container.decodeIfPresent(Int.self, forKey: .usedCharacters)
            limit = try container.decodeIfPresent(Int.self, forKey: .limit)
                ?? container.decodeIfPresent(Int.self, forKey: .total)
                ?? container.decodeIfPresent(Int.self, forKey: .limitCharacters)
        }
    }

    public static func parse(
        data: Data,
        observedAt: Date = Date(),
        fileModifiedAt: Date?
    ) throws -> CurrentTypelessState {
        let storage = try JSONDecoder().decode(Storage.self, from: data)
        let quota: QuotaSnapshot?
        if let used = storage.quotaUsage?.used,
           let limit = storage.quotaUsage?.limit,
           limit > 0 {
            quota = QuotaSnapshot(
                usedCharacters: used,
                limitCharacters: limit,
                observedAt: fileModifiedAt ?? observedAt,
                source: .typelessLocalStorage
            )
        } else {
            quota = nil
        }

        return CurrentTypelessState(
            email: storage.userData?.email,
            displayName: storage.userData?.name,
            planName: storage.userData?.subscriptionPlanName,
            quota: quota,
            observedAt: observedAt,
            sourceModifiedAt: fileModifiedAt
        )
    }
}

public enum VisibleQuotaParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"^\s*([0-9][0-9,\s]*)\s*/\s*([0-9][0-9,\s]*)\s*(字|words?)\s*$"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ texts: [String], observedAt: Date = Date()) -> QuotaSnapshot? {
        for text in texts {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  let usedRange = Range(match.range(at: 1), in: text),
                  let limitRange = Range(match.range(at: 2), in: text),
                  let used = integer(from: String(text[usedRange])),
                  let limit = integer(from: String(text[limitRange])),
                  limit > 0
            else {
                continue
            }
            return QuotaSnapshot(
                usedCharacters: used,
                limitCharacters: limit,
                observedAt: observedAt,
                source: .typelessAccessibility
            )
        }
        return nil
    }

    public static func indicatesWeeklyLimitReached(_ texts: [String]) -> Bool {
        let recognized = Set([
            "weekly limit reached",
            "已达到每周限制",
            "每周限制已达",
            "每周限制已达到",
            "每週限制已達",
        ])
        return texts.contains { text in
            recognized.contains(
                text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
    }

    private static func integer(from text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }
}
