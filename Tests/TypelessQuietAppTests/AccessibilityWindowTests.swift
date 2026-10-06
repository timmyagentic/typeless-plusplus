import ApplicationServices
import XCTest
@testable import TypelessQuietApp

final class AccessibilityWindowTests: XCTestCase {
    private let floating = AXUIElementCreateApplication(41_001)
    private let hub = AXUIElementCreateApplication(41_002)
    private let focused = AXUIElementCreateApplication(41_003)

    func testMainHubIsIncludedWhenWindowListOnlyContainsFloatingBar() {
        let attributes: [String: CFTypeRef] = [
            "AXWindows": [floating] as CFArray,
            "AXMainWindow": hub,
            "AXFocusedWindow": hub,
        ]
        let windows = AccessibilityElementReader().windowElements { attributes[$0] }
        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.contains { CFEqual($0, floating) })
        XCTAssertTrue(windows.contains { CFEqual($0, hub) })
    }

    func testFocusedWindowStillWorksWhenWindowListAndMainWindowAreUnavailable() {
        let windows = AccessibilityElementReader().windowElements { name in
            name == "AXFocusedWindow" ? focused : nil
        }
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows.first.map { CFEqual($0, focused) } == true)
    }

    func testSameWindowAcrossAllAttributesIsOnlyIncludedOnce() {
        let attributes: [String: CFTypeRef] = [
            "AXWindows": [hub, floating] as CFArray,
            "AXMainWindow": hub,
            "AXFocusedWindow": hub,
        ]
        let windows = AccessibilityElementReader().windowElements { attributes[$0] }
        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(CFEqual(windows[0], hub))
        XCTAssertTrue(CFEqual(windows[1], floating))
    }

    func testWrongAttributeTypesAreIgnoredWithoutLosingValidFocusedWindow() {
        let attributes: [String: CFTypeRef] = [
            "AXWindows": "unexpected" as CFString,
            "AXMainWindow": [hub] as CFArray,
            "AXFocusedWindow": focused,
        ]
        let windows = AccessibilityElementReader().windowElements { attributes[$0] }
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(windows.first.map { CFEqual($0, focused) } == true)
    }
}
