import Foundation
import TypelessQuietCore

enum OfficialQuotaFailureCode: String, Codable, Sendable {
    case sessionUnavailable, invalidSession, identityMismatch, sessionChanged
    case unauthorized, rateLimited, networkUnavailable, invalidResponse, redirectBlocked
}

struct OfficialQuotaFailure: Error, Equatable, Sendable, LocalizedError {
    let code: OfficialQuotaFailureCode
    var retryAfter: TimeInterval? = nil

    var errorDescription: String? {
        switch code {
        case .sessionUnavailable: "尚未找到当前登录会话，请先在 Typeless 官方客户端登录。"
        case .invalidSession: "当前登录会话暂不可读，等待 Typeless 更新登录状态。"
        case .identityMismatch, .sessionChanged: "登录状态正在变化，尚未采用本次额度。"
        case .unauthorized: "官方登录会话已失效，请在 Typeless 完成登录后重试。"
        case .rateLimited: "官方服务请求较多，稍后自动同步时再试。"
        case .networkUnavailable: "暂时无法连接官方服务，保留原同步时间。"
        case .invalidResponse: "官方服务暂未提供可识别的周额度。"
        case .redirectBlocked: "官方查询地址发生变化，已停止本次同步。"
        }
    }
}

/// Request-scoped credentials. This type deliberately has no Codable conformance.
struct OfficialQuotaSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let email: String
    let userID: String
    let revision: String
    private let accessToken: String

    init(email: String, userID: String, accessToken: String, revision: String) {
        self.email = email
        self.userID = userID
        self.accessToken = accessToken
        self.revision = revision
    }

    func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
    }

    var description: String { "OfficialQuotaSession(redacted)" }
    var debugDescription: String { description }
}

protocol OfficialQuotaSessionReading: Sendable {
    func read() throws -> OfficialQuotaSession
    func revision() throws -> String
}

struct OfficialQuotaHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
    var retryAfter: TimeInterval? = nil
}

protocol OfficialQuotaHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> OfficialQuotaHTTPResponse
}

struct OfficialQuotaObservation: Equatable, Sendable {
    let email: String
    let revision: String
    let quota: QuotaSnapshot
}

protocol OfficialQuotaFetching: Sendable {
    func sessionRevision() throws -> String
    func fetch(email: String, revision: String) async throws -> OfficialQuotaObservation
}

struct OfficialQuotaAPIClient: OfficialQuotaFetching {
    let sessions: any OfficialQuotaSessionReading
    let transport: any OfficialQuotaHTTPTransport
    var now: @Sendable () -> Date = { Date() }

    func sessionRevision() throws -> String { try sessions.revision() }

    func fetch(email: String, revision: String) async throws -> OfficialQuotaObservation {
        let session = try await Task.detached { try sessions.read() }.value
        guard session.email == AccountProfile.normalizedEmail(email) else {
            throw OfficialQuotaFailure(code: .identityMismatch)
        }
        guard session.revision == revision else { throw OfficialQuotaFailure(code: .sessionChanged) }
        try Task.checkCancellation()

        let identity: Envelope<Identity> = try await request("/user/get_user_info", method: "GET", session: session)
        guard identity.status == "OK", let identity = identity.data else {
            throw OfficialQuotaFailure(code: .invalidResponse)
        }
        guard identity.user_id == session.userID,
              identity.email.flatMap(AccountProfile.normalizedEmail) == session.email else {
            throw OfficialQuotaFailure(code: .identityMismatch)
        }
        try Task.checkCancellation()
        let usage: Envelope<Usage> = try await request("/user/usage_stats", method: "POST", session: session)
        guard usage.status == "OK", let quota = usage.data?.voice_transcription,
              quota.week_word_usage_value >= 0, quota.week_word_usage_limit > 0 else {
            throw OfficialQuotaFailure(code: .invalidResponse)
        }
        let observedAt = now()
        let currentRevision = try await Task.detached { try sessions.revision() }.value
        guard currentRevision == session.revision else { throw OfficialQuotaFailure(code: .sessionChanged) }
        try Task.checkCancellation()
        return OfficialQuotaObservation(email: session.email, revision: session.revision,
            quota: QuotaSnapshot(usedCharacters: quota.week_word_usage_value,
                limitCharacters: quota.week_word_usage_limit, observedAt: observedAt, source: .typelessOfficialAPI))
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let status: String?
        let data: Value?
    }
    private struct Identity: Decodable {
        let email: String?
        let user_id: String?
    }
    private struct Usage: Decodable {
        struct Voice: Decodable {
            let week_word_usage_value: Int
            let week_word_usage_limit: Int
        }
        let voice_transcription: Voice?
    }

    private func request<Value: Decodable>(_ path: String, method: String,
                                           session: OfficialQuotaSession) async throws -> Value {
        var request = URLRequest(url: URL(string: "https://api.typeless.com" + path)!)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.authorize(&request)
        if method == "POST" { request.httpBody = Data("{}".utf8) }
        let response: OfficialQuotaHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as OfficialQuotaFailure { throw error }
        catch { throw OfficialQuotaFailure(code: .networkUnavailable) }
        switch response.statusCode {
        case 200: break
        case 300..<400: throw OfficialQuotaFailure(code: .redirectBlocked)
        case 401, 403: throw OfficialQuotaFailure(code: .unauthorized)
        case 429: throw OfficialQuotaFailure(code: .rateLimited, retryAfter: response.retryAfter)
        default: throw OfficialQuotaFailure(code: .networkUnavailable)
        }
        guard response.data.count <= 1_048_576 else { throw OfficialQuotaFailure(code: .invalidResponse) }
        do { return try JSONDecoder().decode(Value.self, from: response.data) }
        catch { throw OfficialQuotaFailure(code: .invalidResponse) }
    }
}

/// No cookie jar, credential store, persistent cache, or redirected authentication.
final class OfficialQuotaURLSessionTransport: NSObject, OfficialQuotaHTTPTransport,
                                               URLSessionTaskDelegate, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> OfficialQuotaHTTPResponse {
        guard let url = request.url, url.scheme == "https", url.host == "api.typeless.com",
              url.port == nil, url.user == nil, url.password == nil, url.query == nil,
              ["/user/get_user_info", "/user/usage_stats"].contains(url.path) else {
            throw OfficialQuotaFailure(code: .redirectBlocked)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OfficialQuotaFailure(code: .invalidResponse)
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return OfficialQuotaHTTPResponse(statusCode: response.statusCode, data: data, retryAfter: retryAfter)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
