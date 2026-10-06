import Foundation
import XCTest
@testable import TypelessQuietApp
@testable import TypelessQuietCore

final class Typeless281CompatibilityTests: XCTestCase {
    private let hub = "file:///Applications/Typeless.app/Contents/Resources/app.asar/dist/renderer/hub.html"

    func testVersionChangesWhileManagerKeepsRunning() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        defer { try? FileManager.default.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = contents.appendingPathComponent("Info.plist")
        func install(_ version: String) throws {
            let values = ["CFBundleIdentifier": "example.typeless.fixture",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
                .write(to: info, options: .atomic)
        }
        try install("2.6.0")
        let cachedBundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(cachedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "2.6.0")
        XCTAssertEqual(TypelessCurrentStateReader.installedVersion(in: [app]), "2.6.0")
        try install("2.8.1")
        XCTAssertEqual(TypelessCurrentStateReader.installedVersion(in: [app]), "2.8.1")
        withExtendedLifetime(cachedBundle) {}
    }

    func testCollapsedAccountPaneConfirmsIdentityIn281() {
        let evidence = TypelessWindowEvidence(windows: [TypelessWindowSnapshot(
            documents: [hub], texts: ["账户 电子邮件 person@example.com 订阅 Free"],
            buttonNames: ["账户", "设置", "退出"])])
        XCTAssertEqual(evidence.confirmedEmail, "person@example.com")
    }

    func testCollapsedAccountPaneSupportsEnglishAndTraditionalChinese() {
        for fixture in [
            ("Account Email person@example.com Subscription Free", Set(["Account", "Settings", "Log out"])),
            ("帳戶 電子郵件 person@example.com 訂閱 Free", Set(["帳戶", "設定", "登出"])),
        ] {
            let evidence = TypelessWindowEvidence(windows: [TypelessWindowSnapshot(
                documents: [hub], texts: [fixture.0], buttonNames: fixture.1)])
            XCTAssertEqual(evidence.confirmedEmail, "person@example.com")
        }
    }

    func testHistoryTextAndOtherDocumentsCannotConfirmCollapsedIdentity() {
        for fixture in [
            TypelessWindowSnapshot(documents: [hub],
                texts: ["账户 电子邮件 person@example.com 订阅 Free"], buttonNames: ["首页", "历史记录"]),
            TypelessWindowSnapshot(documents: ["file:///tmp/history.html"],
                texts: ["账户 电子邮件 person@example.com 订阅 Free"], buttonNames: ["账户", "设置", "退出"]),
            TypelessWindowSnapshot(documents: [hub],
                texts: ["说过：账户 电子邮件 person@example.com 订阅 Free"], buttonNames: ["账户", "设置", "退出"]),
        ] {
            XCTAssertNil(TypelessWindowEvidence(windows: [fixture]).confirmedEmail)
        }
    }

    func testConflictingCollapsedIdentitiesFailClosed() {
        let evidence = TypelessWindowEvidence(windows: [TypelessWindowSnapshot(
            documents: [hub], texts: ["账户 电子邮件 person@example.com 订阅 Free",
                "账户 电子邮件 second@example.com 订阅 Free"], buttonNames: ["账户", "设置", "退出"])])
        XCTAssertNil(evidence.confirmedEmail)
    }

    func testNewFreeLimitUsesOfficialValueRatherThanLegacyEightThousand() throws {
        let quota = try XCTUnwrap(VisibleQuotaParser.parse(["106 / 2,000 字"]))
        XCTAssertEqual(quota.usedCharacters, 106)
        XCTAssertEqual(quota.limitCharacters, 2_000)
        XCTAssertEqual(quota.remainingCharacters, 1_894)
    }
}
