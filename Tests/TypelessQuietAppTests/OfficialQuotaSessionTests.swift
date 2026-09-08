import Foundation
import XCTest
@testable import TypelessQuietApp

final class OfficialQuotaSessionTests: XCTestCase {
    // Independently encrypted with Node crypto, including a non-UTF8 IV.
    private let armFixture = "AAH//sMo4iihEPCQgAB/QTq32J5obTKk5S1u1SO9qYljrzlk0vF2wtykMfdREJ/2Qpr880EQgztIVtbx4/uNymzsDkbMrDngLSZ3J7ixn/TVDLGn1jY/4ms6YJ2Bc/uu/ONhhmHWWWU6JRT+HSkm+qx5rETwOX4/aIrEoSFbXfkYrIvhQuiaKzET4BoBltzAgVPAbkBif9L9m7ny1QMVXJVBSAyivBg1KKda5eKw5Kgv"
    private let intelFixture = "AAH//sMo4iihEPCQgAB/QTrRL8vlgoZe8Wg8WUErUxRKkrVT14mjLVmJ4ETR7gcS2kCI6LaJ8OB1kkqhpZi8Q6nQ+Z5Z7K7eSYgc9a2e98wW57SyQXK+bNxOsZAnqJ8WZJhbbSwoZ0xbkvSiCY+/awR3EkFlCyUk7wX45wnWKP4AN52I2FDM+Ak5a+W/awbn+g84GIUgNRePv+dcXAICXUgyYpmpN3TalyoFJo8/UmQH"

    func testReadsBothNativeFormatsWithoutWritingSessionFiles() throws {
        for (signature, fixture) in [("darwin-arm64", armFixture), ("darwin-x64", intelFixture)] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let data = try XCTUnwrap(Data(base64Encoded: fixture))
            let sessionURL = directory.appendingPathComponent("user-data.json")
            try data.write(to: sessionURL)
            let storage = Data(#"{"userData":{"email":"current@example.com"}}"#.utf8)
            try storage.write(to: directory.appendingPathComponent("app-storage.json"))
            let reader = OfficialQuotaSessionReader(directory: directory, platformSignature: signature)
            let session = try reader.read()
            XCTAssertEqual(session.email, "current@example.com")
            XCTAssertEqual(session.userID, "fixture-user")
            XCTAssertEqual(session.revision, try reader.revision())
            var request = URLRequest(url: URL(string: "https://example.test")!)
            session.authorize(&request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
            XCTAssertEqual(try Data(contentsOf: sessionURL), data)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("app-storage.json")), storage)
            XCTAssertFalse(String(reflecting: session).contains("fixture-secret"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        }
    }

    func testStorageIdentityAndEncryptedCredentialMustMatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(base64Encoded: armFixture)!.write(to: directory.appendingPathComponent("user-data.json"))
        let storageURL = directory.appendingPathComponent("app-storage.json")
        try Data(#"{"userData":{"email":"current@example.com"}}"#.utf8).write(to: storageURL)
        let reader = OfficialQuotaSessionReader(directory: directory)
        let before = try reader.revision()
        try Data(#"{"userData":{"email":"other@example.com"}}"#.utf8).write(to: storageURL)
        XCTAssertNotEqual(try reader.revision(), before)
        XCTAssertThrowsError(try reader.read()) { error in
            XCTAssertEqual((error as? OfficialQuotaFailure)?.code, .identityMismatch)
        }
    }

    func testRejectsMalformedAndUnsupportedSessionFormats() throws {
        let fixture = try XCTUnwrap(Data(base64Encoded: armFixture))
        var wrongMarker = fixture
        wrongMarker[16] = 0
        for data in [Data(), Data(fixture.prefix(32)), wrongMarker, Data(fixture.dropLast()),
                     Data(repeating: 0, count: 1_048_577)] {
            XCTAssertThrowsError(try OfficialQuotaSessionReader.decrypt(data, platformSignature: "darwin-arm64"))
        }
        XCTAssertThrowsError(try OfficialQuotaSessionReader.decrypt(fixture, platformSignature: "unknown"))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
