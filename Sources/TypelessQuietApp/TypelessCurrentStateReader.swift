import AppKit
import ApplicationServices
import Foundation
import TypelessQuietCore

struct TypelessStateReadResult: Sendable {
    let state: CurrentTypelessState
    let storageURL: URL
    let appVersion: String?
    let appRunning: Bool
    let quotaProvenance: TypelessQuotaReadProvenance

    init(
        state: CurrentTypelessState,
        storageURL: URL,
        appVersion: String?,
        appRunning: Bool,
        quotaProvenance: TypelessQuotaReadProvenance? = nil
    ) {
        self.state = state
        self.storageURL = storageURL
        self.appVersion = appVersion
        self.appRunning = appRunning
        if let quotaProvenance {
            self.quotaProvenance = quotaProvenance
        } else {
            self.quotaProvenance = switch state.quota?.source {
            case .typelessAccessibility: .visibleAccessibility
            case .typelessLocalStorage: .localStorage
            case .typelessOfficialAPI: .officialAPI
            case nil: .unavailable
            }
        }
    }
}

enum TypelessQuotaReadProvenance: String, Codable, Equatable, Sendable {
    case unavailable
    case awaitingIdentityConfirmation
    case requiresClientRestart
    case localStorage
    case visibleAccessibility
    case cachedAccessibility
    case visibleWeeklyLimitReached
    case officialAPI
}

struct TypelessVisibleQuotaResolution: Equatable, Sendable {
    let quota: QuotaSnapshot?
    let provenance: TypelessQuotaReadProvenance

    static let unavailable = TypelessVisibleQuotaResolution(
        quota: nil,
        provenance: .unavailable
    )
}

final class TypelessVisibleQuotaCache {
    private struct Entry {
        let email: String
        let processIdentifier: pid_t
        let quota: QuotaSnapshot
    }

    private let maximumAge: TimeInterval
    private let lock = NSLock()
    private var entry: Entry?
    private var identity: String?
    private var process: pid_t?
    private var identityConfirmed = false
    private var processLaunchDate: Date?
    private var requiresRestart = false
    private let continuityURL: URL?

    private struct Continuity: Codable, Equatable {
        let email: String?
        let processIdentifier: pid_t?
        let processLaunchDate: Date?
        let requiresRestart: Bool
    }
    private var savedContinuity: Continuity?

    private func persistContinuity() -> Bool {
        guard let continuityURL else { return true }
        let value = Continuity(email: identity, processIdentifier: process,
            processLaunchDate: processLaunchDate, requiresRestart: requiresRestart)
        guard value != savedContinuity else { return true }
        do {
            let parent = continuityURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try JSONEncoder().encode(value).write(to: continuityURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: continuityURL.path)
            savedContinuity = value
            return true
        } catch { return false }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
        identityConfirmed = false
        requiresRestart = true
        _ = persistContinuity()
    }

    init(maximumAge: TimeInterval = 300, continuityURL: URL? = nil) {
        self.maximumAge = maximumAge
        self.continuityURL = continuityURL
        // On first production use, establish a fresh official process before trusting
        // renderer quota. Persist quarantine so restarting Typeless++ cannot bypass it.
        requiresRestart = continuityURL != nil
        if let continuityURL, let data = try? Data(contentsOf: continuityURL),
           let saved = try? JSONDecoder().decode(Continuity.self, from: data) {
            savedContinuity = saved
            identity = saved.email
            process = saved.processIdentifier
            processLaunchDate = saved.processLaunchDate
            // A previous confirmation cannot cover changes while this manager was
            // stopped, even when the official client ends on the same email again.
            // A different official process generation still clears this in resolve.
            requiresRestart = true
        }
    }

    func resolve(
        email: String?,
        processIdentifier: pid_t,
        texts: [String],
        observedAt: Date,
        confirmedEmail: String? = nil,
        processLaunchDate: Date? = nil
    ) -> TypelessVisibleQuotaResolution {
        lock.lock()
        defer { lock.unlock() }

        let normalizedEmail = email.flatMap(AccountProfile.normalizedEmail)
        let sameProcess = process == processIdentifier && self.processLaunchDate == processLaunchDate
        if !sameProcess {
            // A newly launched official process cannot retain the previous renderer.
            if process != nil { requiresRestart = false }
            entry = nil
            identityConfirmed = false
        } else if identity != normalizedEmail {
            requiresRestart = true
            entry = nil
            identityConfirmed = false
        }
        identity = normalizedEmail
        process = processIdentifier
        self.processLaunchDate = processLaunchDate
        guard persistContinuity() else { return .unavailable }
        guard let normalizedEmail else { return .unavailable }
        guard !requiresRestart else {
            return TypelessVisibleQuotaResolution(quota: nil, provenance: .requiresClientRestart)
        }
        // Require evidence from the official Account pane before binding a renderer's
        // quota to local storage. Waiting alone cannot prove that the old UI is gone.
        if let confirmedEmail {
            identityConfirmed = AccountProfile.normalizedEmail(confirmedEmail) == normalizedEmail
            if !identityConfirmed { entry = nil }
        }
        guard identityConfirmed else {
            return TypelessVisibleQuotaResolution(quota: nil, provenance: .awaitingIdentityConfirmation)
        }
        if let visible = VisibleQuotaParser.parse(texts, observedAt: observedAt) {
            entry = Entry(email: normalizedEmail, processIdentifier: processIdentifier, quota: visible)
            return TypelessVisibleQuotaResolution(quota: visible, provenance: .visibleAccessibility)
        }

        guard let entry,
              entry.email == normalizedEmail,
              entry.processIdentifier == processIdentifier,
              entry.quota.isFresh(at: observedAt, maximumAge: maximumAge)
        else {
            self.entry = nil
            return .unavailable
        }

        if VisibleQuotaParser.indicatesWeeklyLimitReached(texts) {
            let reached = QuotaSnapshot(
                usedCharacters: entry.quota.limitCharacters,
                limitCharacters: entry.quota.limitCharacters,
                observedAt: observedAt,
                source: .typelessAccessibility
            )
            self.entry = Entry(
                email: normalizedEmail,
                processIdentifier: processIdentifier,
                quota: reached
            )
            return TypelessVisibleQuotaResolution(
                quota: reached,
                provenance: .visibleWeeklyLimitReached
            )
        }

        return TypelessVisibleQuotaResolution(
            quota: entry.quota,
            provenance: .cachedAccessibility
        )
    }
}

enum TypelessStateReaderError: LocalizedError {
    case storageNotFound

    var errorDescription: String? {
        switch self {
        case .storageNotFound:
            "未找到 Typeless app-storage.json"
        }
    }
}

protocol TypelessCurrentStateReading {
    func read() throws -> TypelessStateReadResult
}

private struct TypelessAXIdentitySet {
    private var buckets: [CFHashCode: [AXUIElement]] = [:]

    mutating func insert(_ element: AXUIElement) -> Bool {
        let hash = CFHash(element)
        if buckets[hash, default: []].contains(where: { CFEqual($0, element) }) {
            return false
        }
        buckets[hash, default: []].append(element)
        return true
    }
}

struct TypelessCurrentStateReader: TypelessCurrentStateReading {
    private let fileManager = FileManager.default
    private let visibleQuotaCache: TypelessVisibleQuotaCache

    init(visibleQuotaCache: TypelessVisibleQuotaCache? = nil) {
        self.visibleQuotaCache = visibleQuotaCache ?? TypelessVisibleQuotaCache(
            continuityURL: Self.continuityURL
        )
    }

    private static var continuityURL: URL {
        let directory = ProcessInfo.processInfo.environment["TYPELESS_PLUSPLUS_DATA_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeless++", isDirectory: true)
        return directory.appendingPathComponent("quota-continuity.json")
    }

    func read() throws -> TypelessStateReadResult {
        var completed = false
        defer { if !completed { visibleQuotaCache.invalidate() } }
        guard let storageURL = Self.storageCandidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw TypelessStateReaderError.storageNotFound
        }

        let data = try Data(contentsOf: storageURL)
        let attributes = try? fileManager.attributesOfItem(atPath: storageURL.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let observedAt = Date()
        var state = try TypelessLocalStateParser.parse(
            data: data,
            observedAt: observedAt,
            fileModifiedAt: modifiedAt
        )
        var quotaProvenance: TypelessQuotaReadProvenance = state.quota == nil
            ? .unavailable
            : .localStorage

        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: TargetPromptMatcher.targetBundleIdentifier
        )
        let liveQuotaDisabled = ProcessInfo.processInfo.environment[
            "TYPELESS_PLUSPLUS_DISABLE_LIVE_QUOTA"
        ] == "true"
        if let running = runningApps.first {
            let windows = accessibilityWindows(processIdentifier: running.processIdentifier)
            let snapshot = TypelessWindowEvidence(windows: windows)
            // Storage and the renderer update independently during login. Discard the
            // entire mixed observation if the identity changes while AX is being read.
            let after = try TypelessLocalStateParser.parse(
                data: Data(contentsOf: storageURL), observedAt: Date(), fileModifiedAt: modifiedAt
            )
            guard after.email == state.email else {
                visibleQuotaCache.invalidate()
                return TypelessStateReadResult(state: after.mergingWithoutQuota(), storageURL: storageURL,
                    appVersion: installedTypelessVersion, appRunning: true,
                    quotaProvenance: .awaitingIdentityConfirmation)
            }
            state.activity = snapshot.activity
            if !liveQuotaDisabled {
                let resolution = visibleQuotaCache.resolve(
                    email: state.email,
                    processIdentifier: running.processIdentifier,
                    texts: snapshot.quotaTexts,
                    observedAt: observedAt,
                    confirmedEmail: snapshot.confirmedEmail,
                    processLaunchDate: running.launchDate
                )
                if state.quota == nil { quotaProvenance = resolution.provenance }
                if let quota = resolution.quota {
                    state = state.merging(quota: quota)
                    quotaProvenance = resolution.provenance
                }
            }
        }

        completed = true
        return TypelessStateReadResult(
            state: state,
            storageURL: storageURL,
            appVersion: installedTypelessVersion,
            appRunning: !runningApps.isEmpty,
            quotaProvenance: quotaProvenance
        )
    }

    static var storageCandidates: [URL] {
        if let override = ProcessInfo.processInfo.environment["TYPELESS_PLUSPLUS_TYPELESS_SUPPORT_DIR"] {
            return [URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("app-storage.json")]
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["Typeless", "Typeless.exe"].map {
            support.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("app-storage.json")
        }
    }

    private var installedTypelessVersion: String? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Typeless.app"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Typeless.app"),
        ]
        for appURL in candidates where fileManager.fileExists(atPath: appURL.path) {
            if let bundle = Bundle(url: appURL),
               let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                return version
            }
        }
        return nil
    }

    func accessibilityWindows(processIdentifier: pid_t) -> [TypelessWindowSnapshot] {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let windows = elements("AXWindows", of: application)
        return windows.prefix(16).map { window in
            var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
            var index = 0
            var seen = TypelessAXIdentitySet()
            var texts: [String] = []
            var documents: [String] = []
            _ = seen.insert(window)
            while index < queue.count && index < 2_500 {
                let item = queue[index]
                index += 1
                for attribute in ["AXTitle", "AXValue", "AXDescription", "AXHelp"] {
                    if let text = stringAttribute(attribute, of: item.element), !text.isEmpty {
                        texts.append(text)
                    }
                }
                for attribute in ["AXDocument", "AXURL"] {
                    if let document = stringAttribute(attribute, of: item.element) {
                        documents.append(document)
                    }
                }
                guard item.depth < 24 else { continue }
                for child in elements("AXChildren", of: item.element) where seen.insert(child) {
                    queue.append((child, item.depth + 1))
                }
            }
            return TypelessWindowSnapshot(documents: documents, texts: texts)
        }
    }

    private func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0 ..< CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let candidate = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(candidate, to: AXUIElement.self)
        }
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return (unsafeBitCast(value, to: CFURL.self) as URL).absoluteString
        }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeBitCast(value, to: CFString.self) as String
    }
}

private extension CurrentTypelessState {
    func mergingWithoutQuota() -> CurrentTypelessState {
        var copy = self
        copy.quota = nil
        copy.activity = .unknown
        return copy
    }
}

struct TypelessWindowSnapshot {
    let documents: [String]
    let texts: [String]

    func containsDocument(_ name: String) -> Bool {
        documents.contains { value in
            guard let url = URL(string: value), url.isFileURL else { return false }
            return url.path.hasSuffix("/app.asar/dist/renderer/" + name)
        }
    }
}

struct TypelessWindowEvidence {
    let quotaTexts: [String]
    let confirmedEmail: String?
    let activity: TypelessActivityState

    init(windows: [TypelessWindowSnapshot]) {
        let hubs = windows.filter { $0.containsDocument("hub.html") }
        quotaTexts = hubs.flatMap(\.texts)
        // Electron exposes the Account pane as adjacent static labels. A single
        // dictation-history string containing an email is not identity evidence.
        let accountLabels: Set<String> = ["账户", "帳戶", "Account"]
        let emailLabels: Set<String> = ["电子邮件", "電子郵件", "Email"]
        let subscriptionLabels: Set<String> = ["订阅", "訂閱", "Subscription"]
        var identities = Set<String>()
        for hub in hubs {
            var labels: [String] = []
            for text in hub.texts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if labels.last != trimmed { labels.append(trimmed) }
            }
            guard labels.count >= 4 else { continue }
            for index in 0 ... labels.count - 4 {
                if accountLabels.contains(labels[index]), emailLabels.contains(labels[index + 1]),
                   let email = AccountProfile.normalizedEmail(labels[index + 2]),
                   subscriptionLabels.contains(labels[index + 3]) {
                    identities.insert(email)
                }
            }
        }
        confirmedEmail = identities.count == 1 ? identities.first : nil
        let floatingTexts = windows.filter { $0.containsDocument("floating-bar.html") }.flatMap(\.texts)
        activity = TypelessActivityDetector.detect(texts: floatingTexts)
    }
}
