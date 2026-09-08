import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

private final class TestQuotaSessions: OfficialQuotaSessionReading, @unchecked Sendable {
    var email = "current@example.com"
    var generation = "session-one"
    var readCount = 0
    func read() throws -> OfficialQuotaSession {
        readCount += 1
        return OfficialQuotaSession(email: email, userID: "fixture-user", accessToken: "fixture-secret",
                                    revision: generation)
    }
    func revision() throws -> String { generation }
}

private actor TestQuotaHTTP: OfficialQuotaHTTPTransport {
    private(set) var requests: [URLRequest] = []
    var responses: [OfficialQuotaHTTPResponse]
    var afterRequest: (@Sendable (Int) -> Void)?

    init(_ bodies: [String], status: Int = 200) {
        responses = bodies.map { OfficialQuotaHTTPResponse(statusCode: status, data: Data($0.utf8)) }
    }

    func setAfterRequest(_ action: @escaping @Sendable (Int) -> Void) { afterRequest = action }

    func send(_ request: URLRequest) async throws -> OfficialQuotaHTTPResponse {
        requests.append(request)
        afterRequest?(requests.count)
        return responses.removeFirst()
    }
}

final class OfficialQuotaAPITests: XCTestCase {
    private let identity = #"{"status":"OK","data":{"email":"current@example.com","user_id":"fixture-user"}}"#
    private let usage = #"{"status":"OK","data":{"voice_transcription":{"week_word_usage_value":652,"week_word_usage_limit":8000}}}"#

    func testReadsServerQuotaWithoutOpeningOfficialPages() async throws {
        let sessions = TestQuotaSessions()
        let transport = TestQuotaHTTP([identity, usage])
        let observedAt = Date(timeIntervalSince1970: 2_000)
        let client = OfficialQuotaAPIClient(sessions: sessions, transport: transport, now: { observedAt })

        let result = try await client.fetch(email: sessions.email, revision: sessions.generation)

        XCTAssertEqual(result.email, sessions.email)
        XCTAssertEqual(result.quota.usedCharacters, 652)
        XCTAssertEqual(result.quota.limitCharacters, 8000)
        XCTAssertEqual(result.quota.observedAt, observedAt)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://api.typeless.com/user/get_user_info", "https://api.typeless.com/user/usage_stats",
        ])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret" })
        XCTAssertTrue(requests.allSatisfy { $0.url?.query == nil })
        XCTAssertEqual(String(data: requests[1].httpBody ?? Data(), encoding: .utf8), "{}")
        XCTAssertFalse(String(reflecting: try sessions.read()).contains("fixture-secret"))
    }

    func testMismatchedServerIdentityPreventsQuotaRequest() async {
        let transport = TestQuotaHTTP([#"{"status":"OK","data":{"email":"other@example.com","user_id":"other-user"}}"#])
        await assertFailure(.identityMismatch, bodies: transport)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testSessionChangeWhileRequestRunsDiscardsQuota() async {
        let sessions = TestQuotaSessions()
        let transport = TestQuotaHTTP([identity, usage])
        await transport.setAfterRequest { count in
            if count == 2 { sessions.generation = "session-two" }
        }
        await assertFailure(.sessionChanged, bodies: transport, sessions: sessions)
    }

    func testCredentialIdentityMismatchDoesNotSendNetworkRequest() async {
        let sessions = TestQuotaSessions()
        sessions.email = "other@example.com"
        let transport = TestQuotaHTTP([])
        await assertFailure(.identityMismatch, bodies: transport, sessions: sessions)
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testMissingNegativeBooleanAndErrorQuotaAreNotAccepted() async {
        for body in [
            #"{"status":"OK","data":{"voice_transcription":{}}}"#,
            #"{"status":"OK","data":{"voice_transcription":{"week_word_usage_value":-1,"week_word_usage_limit":8000}}}"#,
            #"{"status":"OK","data":{"voice_transcription":{"week_word_usage_value":true,"week_word_usage_limit":8000}}}"#,
            #"{"status":"OK","data":{"voice_transcription":{"week_word_usage_value":0,"week_word_usage_limit":0}}}"#,
            #"{"status":"ERROR","data":{"voice_transcription":{"week_word_usage_value":0,"week_word_usage_limit":8000}}}"#,
        ] {
            await assertFailure(.invalidResponse, bodies: TestQuotaHTTP([identity, body]))
        }
    }

    func testHTTPFailuresUseFixedErrorsWithoutResponseBody() async {
        for (status, code) in [(401, OfficialQuotaFailureCode.unauthorized), (429, .rateLimited),
                               (500, .networkUnavailable), (302, .redirectBlocked)] {
            await assertFailure(code, bodies: TestQuotaHTTP(["private-response-secret"], status: status))
        }
    }

    func testTransportRejectsOtherHostsAndAllRedirects() async throws {
        let transport = OfficialQuotaURLSessionTransport()
        for address in ["http://api.typeless.com/user/usage_stats", "https://example.com/user/usage_stats",
                        "https://api.typeless.com/user/usage_stats?credential=fixture", "https://api.typeless.com/other"] {
            do {
                _ = try await transport.send(URLRequest(url: URL(string: address)!))
                XCTFail("Unapproved endpoint was accepted")
            } catch let error as OfficialQuotaFailure { XCTAssertEqual(error.code, .redirectBlocked) }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://api.typeless.com/user/usage_stats")!)
        let task = session.dataTask(with: request)
        for address in ["https://example.com", "https://api.typeless.com/user/get_user_info"] {
            let redirected = URLRequest(url: URL(string: address)!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var called = false
            transport.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
                XCTAssertNil($0, "Even same-host redirects cannot forward authentication")
                called = true
            }
            XCTAssertTrue(called)
        }
    }

    private func assertFailure(_ expected: OfficialQuotaFailureCode, bodies: TestQuotaHTTP,
                               sessions: TestQuotaSessions = TestQuotaSessions()) async {
        let client = OfficialQuotaAPIClient(sessions: sessions, transport: bodies)
        do {
            _ = try await client.fetch(email: "current@example.com", revision: "session-one")
            XCTFail("Expected a rejected observation")
        } catch let error as OfficialQuotaFailure {
            XCTAssertEqual(error.code, expected)
            XCTAssertFalse(error.localizedDescription.contains("private-response-secret"))
        } catch { XCTFail("Unexpected unclassified error") }
    }
}
