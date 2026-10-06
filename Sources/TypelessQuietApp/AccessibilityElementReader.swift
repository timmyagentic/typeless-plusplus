import ApplicationServices
import Foundation
import TypelessQuietCore

enum AXScanFailure: Error, Equatable {
    case applicationTraversalLimitExceeded
    case cardTraversalLimitExceeded
}

struct CapturedCard {
    let snapshot: AXNodeSnapshot
    let elementsByPath: [AXNodePath: AXUIElement]
}

// Accessibility descendants form a graph in some Electron apps. Track CF identity so
// shared or cyclic elements are visited once instead of exhausting traversal limits.
private struct AXElementIdentitySet {
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

struct AccessibilityElementReader {
    private let maximumApplicationNodes = 2_500
    private let maximumApplicationDepth = 24
    private let maximumCardNodes = 256
    private let maximumCardDepth = 12

    func windowElements(in application: AXUIElement) -> [AXUIElement] {
        windowElements(readAttribute: { attribute($0, of: application) })
    }

    func windowElements(readAttribute: (String) -> CFTypeRef?) -> [AXUIElement] {
        var windows = readAttribute("AXWindows").map(elementArray(from:)) ?? []
        // Typeless 2.8.1 can omit its hub from AXWindows while exposing it as the
        // main/focused window. Keep those roots available for quota and observers.
        for name in ["AXMainWindow", "AXFocusedWindow"] {
            if let value = readAttribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                windows.append(unsafeBitCast(value, to: AXUIElement.self))
            }
        }
        var seen = AXElementIdentitySet()
        return windows.filter { seen.insert($0) }
    }

    func targetCardElements(in application: AXUIElement) -> Result<[AXUIElement], AXScanFailure> {
        var queue: [(element: AXUIElement, depth: Int)] = [(application, 0)]
        var index = 0
        var cards: [AXUIElement] = []
        var seen = AXElementIdentitySet()
        _ = seen.insert(application)

        while index < queue.count {
            guard index < maximumApplicationNodes else {
                return .failure(.applicationTraversalLimitExceeded)
            }

            let item = queue[index]
            index += 1

            if TargetPromptMatcher.isTargetCardContainer(
                role: stringAttribute("AXRole", of: item.element),
                subrole: stringAttribute("AXSubrole", of: item.element)
            ) {
                cards.append(item.element)
            }

            if item.depth < maximumApplicationDepth {
                for child in childElements(of: item.element) where seen.insert(child) {
                    queue.append((element: child, depth: item.depth + 1))
                }
            }
        }

        return .success(cards)
    }

    func capture(_ card: AXUIElement) -> Result<CapturedCard, AXScanFailure> {
        var visited = 0
        var elementsByPath: [AXNodePath: AXUIElement] = [:]
        var seen = AXElementIdentitySet()
        _ = seen.insert(card)

        do {
            let rootPath = AXNodePath()
            let snapshot = try captureNode(
                card,
                path: rootPath,
                depth: 0,
                visited: &visited,
                seen: &seen,
                elementsByPath: &elementsByPath
            )
            return .success(CapturedCard(
                snapshot: snapshot,
                elementsByPath: elementsByPath
            ))
        } catch {
            return .failure(.cardTraversalLimitExceeded)
        }
    }

    private func captureNode(
        _ element: AXUIElement,
        path: AXNodePath,
        depth: Int,
        visited: inout Int,
        seen: inout AXElementIdentitySet,
        elementsByPath: inout [AXNodePath: AXUIElement]
    ) throws -> AXNodeSnapshot {
        guard visited < maximumCardNodes, depth <= maximumCardDepth else {
            throw AXScanFailure.cardTraversalLimitExceeded
        }

        visited += 1
        elementsByPath[path] = element

        let children = childElements(of: element).filter { seen.insert($0) }
        let childSnapshots = try children.enumerated().map { index, child in
            try captureNode(
                child,
                path: path.appending(index),
                depth: depth + 1,
                visited: &visited,
                seen: &seen,
                elementsByPath: &elementsByPath
            )
        }

        return AXNodeSnapshot(
            role: stringAttribute("AXRole", of: element),
            subrole: stringAttribute("AXSubrole", of: element),
            title: stringAttribute("AXTitle", of: element),
            value: stringAttribute("AXValue", of: element),
            elementDescription: stringAttribute("AXDescription", of: element),
            help: stringAttribute("AXHelp", of: element),
            identifier: stringAttribute("AXIdentifier", of: element),
            domIdentifier: stringAttribute("AXDOMIdentifier", of: element),
            domClassList: stringSetAttribute("AXDOMClassList", of: element),
            frame: frame(of: element),
            actions: actionNames(of: element),
            children: childSnapshots
        )
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let rawValue = attribute("AXChildren", of: element) else {
            return []
        }
        return elementArray(from: rawValue)
    }

    private func elementArray(from rawValue: CFTypeRef) -> [AXUIElement] {
        guard CFGetTypeID(rawValue) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(rawValue, to: CFArray.self)
        return (0 ..< CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else {
                return nil
            }
            let value = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        guard let rawValue = attribute(name, of: element),
              CFGetTypeID(rawValue) == CFStringGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(rawValue, to: CFString.self) as String
    }

    private func stringSetAttribute(_ name: String, of element: AXUIElement) -> Set<String> {
        guard let rawValue = attribute(name, of: element),
              CFGetTypeID(rawValue) == CFArrayGetTypeID()
        else {
            return []
        }

        let array = unsafeBitCast(rawValue, to: CFArray.self)
        return Set((0 ..< CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else {
                return nil
            }
            let value = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(value) == CFStringGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: CFString.self) as String
        })
    }

    private func frame(of element: AXUIElement) -> AXFrame? {
        if let rawFrame = attribute("AXFrame", of: element) {
            if let rect = rectValue(rawFrame) {
                return AXFrame(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
                )
            }
        }

        guard let rawPosition = attribute("AXPosition", of: element),
              let rawSize = attribute("AXSize", of: element)
        else {
            return nil
        }

        guard let point = pointValue(rawPosition),
              let size = sizeValue(rawSize)
        else {
            return nil
        }

        return AXFrame(
            x: point.x,
            y: point.y,
            width: size.width,
            height: size.height
        )
    }

    private func axValue(_ rawValue: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXValue.self)
    }

    private func rectValue(_ rawValue: CFTypeRef) -> CGRect? {
        guard let value = axValue(rawValue) else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    private func pointValue(_ rawValue: CFTypeRef) -> CGPoint? {
        guard let value = axValue(rawValue) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func sizeValue(_ rawValue: CFTypeRef) -> CGSize? {
        guard let value = axValue(rawValue) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func actionNames(of element: AXUIElement) -> Set<String> {
        var rawNames: CFArray?
        guard AXUIElementCopyActionNames(element, &rawNames) == .success,
              let rawNames
        else {
            return []
        }

        return Set((0 ..< CFArrayGetCount(rawNames)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(rawNames, index) else {
                return nil
            }
            let value = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(value) == CFStringGetTypeID() else {
                return nil
            }
            let rawString = unsafeBitCast(value, to: CFString.self)
            return rawString as String
        })
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
