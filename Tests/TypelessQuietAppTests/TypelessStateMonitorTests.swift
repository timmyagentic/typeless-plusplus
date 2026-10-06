import Foundation
import XCTest
@testable import TypelessQuietApp

@MainActor
final class TypelessStateMonitorTests: XCTestCase {
    func testSessionAndUsageWritesTriggerRefreshWithoutAccountPageChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app-storage.json")
        let session = root.appendingPathComponent("user-data.json")
        let usage = root.appendingPathComponent("typeless.db-wal")
        try Data("unchanged account".utf8).write(to: file)
        try Data("initial".utf8).write(to: session)
        try Data("initial".utf8).write(to: usage)
        var changes = 0
        let monitor = TypelessStateMonitor(storageURL: file, debounceDelay: 0.02, observesApplications: false) {
            changes += 1
        }
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let initialChanges = changes
        try Data("new session".utf8).write(to: session, options: .atomic)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertGreaterThan(changes, initialChanges)
        let afterSession = changes
        let handle = try FileHandle(forWritingTo: usage)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("new usage".utf8))
        try handle.close()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertGreaterThan(changes, afterSession, "In-place SQLite WAL writes must refresh quota")
        let settled = changes
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(changes, settled, "No recurring polling")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unchanged account")
    }

    func testAtomicReplacementAndRecreationRefreshWithoutPolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app-storage.json")
        try Data("first".utf8).write(to: file, options: .atomic)
        let initial = expectation(description: "initial read")
        let replacement = expectation(description: "atomic replacement observed")
        let recreation = expectation(description: "recreated storage observed")
        var seen = Set<String>()
        let monitor = TypelessStateMonitor(storageURL: file, debounceDelay: 0.05, observesApplications: false) {
            guard let data = try? Data(contentsOf: file) else { return }
            let value = String(decoding: data, as: UTF8.self)
            guard seen.insert(value).inserted else { return }
            switch value {
            case "first": initial.fulfill()
            case "second": replacement.fulfill()
            case "third": recreation.fulfill()
            default: break
            }
        }
        monitor.start()
        defer { monitor.stop() }
        await fulfillment(of: [initial], timeout: 2)
        try Data("second".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [replacement], timeout: 2)
        try FileManager.default.removeItem(at: file)
        try Data("third".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [recreation], timeout: 2)
        monitor.stop()
        try Data("after-stop".utf8).write(to: file, options: .atomic)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(seen.contains("after-stop"))
    }

    func testAttachesWhenTypelessDirectoryIsCreatedLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Typeless")
        let file = parent.appendingPathComponent("app-storage.json")
        let detected = expectation(description: "new support directory and state detected")
        var delivered = false
        let monitor = TypelessStateMonitor(storageURL: file, debounceDelay: 0.05, observesApplications: false) {
            if !delivered, FileManager.default.fileExists(atPath: file.path) {
                delivered = true
                detected.fulfill()
            }
        }
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        try Data("created".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [detected], timeout: 2)
    }
}
