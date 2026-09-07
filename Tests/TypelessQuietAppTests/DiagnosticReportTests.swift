import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

final class DiagnosticReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 40_000)

    func testExportDropsIdentitiesSecretsFreeFormMessagesAndQuotaValues() throws {
        let account = try AccountProfile(displayName: "PRIVATE_DISPLAY", email: "private@example.test",
            note: "PRIVATE_NOTE auth-secret-value", status: .unknown, hasSecret: true)
        let state = CurrentTypelessState(email: account.email, displayName: account.displayName,
            planName: "PRIVATE_PLAN", quota: QuotaSnapshot(usedCharacters: 1234, limitCharacters: 8765,
                observedAt: now, source: .typelessAccessibility), observedAt: now, sourceModifiedAt: now,
            activity: .unknown)
        let read = TypelessStateReadResult(state: state,
            storageURL: URL(fileURLWithPath: "/Users/private-owner/auth-secret-value.json"),
            appVersion: "https://example.test/?token=auth-secret-value", appRunning: true,
            quotaProvenance: .requiresClientRestart)
        let event = SwitchAuditEvent(transactionID: UUID(), originalAccountID: account.id,
            targetAccountID: UUID(), source: .manual, phase: .failed, occurredAt: now,
            outcome: .verificationRequired, failureCode: .verificationQuotaMissingOrStale)
        let report = DiagnosticReport(applicationVersion: "0.0.1", buildVersion: "9", macOSVersion: "27.0.0",
            readResult: read, accounts: [account], diagnostics: [
                AccountDiagnosticItem(id: "quota", title: "PRIVATE_TITLE", detail: "auth-secret-value", level: .warning),
                AccountDiagnosticItem(id: "secret-\(account.id)", title: "PRIVATE_TITLE", detail: account.email, level: .warning),
                AccountDiagnosticItem(id: "private@example.test", title: "PRIVATE_TITLE", detail: "PRIVATE_NOTE", level: .error)
            ], auditEvents: [event], auditAvailable: false, accessibilityGranted: true, guardEnabled: false, now: now)
        let data = try report.encoded()
        let text = String(decoding: data, as: UTF8.self)

        for forbidden in [account.email, account.id.uuidString, event.transactionID.uuidString,
                          "PRIVATE_", "auth-secret-value", "/Users/", "token=", "1234", "8765"] {
            XCTAssertFalse(text.contains(forbidden), "Unexpected private field in diagnostic export")
        }
        XCTAssertEqual(report.versions.typeless, "unknown")
        XCTAssertEqual(report.client.activity, .unknown)
        XCTAssertEqual(report.client.quotaProvenance, .requiresClientRestart)
        XCTAssertEqual(report.accounts.awaitingVerification, 1)
        XCTAssertEqual(report.checks.map(\.code), [.secretFlagMismatch, .quota])
        XCTAssertEqual(report.recentSwitchEvents.first?.failureCode, .verificationQuotaMissingOrStale)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(DiagnosticReport.self, from: data), report)
    }

    func testMissingStateStaysUnknownAndDoesNotAssumeClientStoppedOrIdle() {
        let report = makeReport()
        XCTAssertNil(report.client.running)
        XCTAssertFalse(report.client.identityReadable)
        XCTAssertEqual(report.client.activity, .unknown)
        XCTAssertEqual(report.client.quotaStatus, .unavailable)
        XCTAssertEqual(report.versions.typeless, "unknown")
    }

    func testChecksCollapseAccountIdentifiersAndBoundAuditHistory() {
        let events = (0..<30).map { _ in
            SwitchAuditEvent(transactionID: UUID(), originalAccountID: nil, targetAccountID: UUID(),
                source: .manual, phase: .failed, occurredAt: now, outcome: .cancelled, failureCode: .cancelled)
        }
        let report = makeReport(diagnostics: [
            AccountDiagnosticItem(id: "secret-first", title: "", detail: "", level: .warning),
            AccountDiagnosticItem(id: "secret-second", title: "", detail: "", level: .error),
            AccountDiagnosticItem(id: "secret-third", title: "", detail: "", level: .success)
        ], events: events)
        XCTAssertEqual(report.checks, [.init(code: .secretFlagMismatch, level: .error)])
        XCTAssertEqual(report.recentSwitchEvents.count, 20)
    }

    func testExportCreatesOwnerOnlyJSONAndReportsWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.json")
        let report = makeReport()
        try report.write(to: url)
        XCTAssertEqual(try Data(contentsOf: url), try report.encoded())
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try report.write(to: root.appendingPathComponent("missing/report.json")))
    }

    private func makeReport(diagnostics: [AccountDiagnosticItem] = [], events: [SwitchAuditEvent] = []) -> DiagnosticReport {
        DiagnosticReport(applicationVersion: "0.0.1", buildVersion: "9", macOSVersion: "27.0.0",
            readResult: nil, accounts: [], diagnostics: diagnostics, auditEvents: events,
            auditAvailable: true, accessibilityGranted: false, guardEnabled: false, now: now)
    }
}
