import AppKit
import ApplicationServices
import Foundation
import TypelessQuietCore

private let stateObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<TypelessStateMonitor>.fromOpaque(refcon).takeUnretainedValue().scheduleRefresh()
}

/// Observes official storage and UI changes independently of the optional prompt closer.
/// All callbacks run on the main run loop; repeated notifications share one bounded refresh.
final class TypelessStateMonitor: NSObject {
    private let storageURL: URL
    private let onChange: () -> Void
    private let debounceDelay: TimeInterval
    private let observesApplications: Bool
    private var directorySource: DispatchSourceFileSystemObject?
    private var watchedDirectory: URL?
    private var storageStamp: Date?
    private var pendingRefresh: DispatchWorkItem?
    private var observer: AXObserver?
    private var processID: pid_t?
    private var registrations: [(AXUIElement, String)] = []
    private var started = false

    init(storageURL: URL, debounceDelay: TimeInterval = 0.6,
         observesApplications: Bool = true, onChange: @escaping () -> Void) {
        self.storageURL = storageURL
        self.debounceDelay = debounceDelay
        self.observesApplications = observesApplications
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard !started else { return }
        started = true
        attachDirectory()
        if observesApplications {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification,
                         NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didActivateApplicationNotification] {
                center.addObserver(self, selector: #selector(applicationChanged), name: name, object: nil)
            }
            reconcileObserver()
        }
        scheduleRefresh()
    }

    func stop() {
        started = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        directorySource?.cancel()
        directorySource = nil
        watchedDirectory = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detachObserver()
    }

    @objc private func applicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == TargetPromptMatcher.targetBundleIdentifier ||
                app.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
        reconcileObserver()
        scheduleRefresh()
    }

    fileprivate func scheduleRefresh() {
        guard started, pendingRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.pendingRefresh = nil
            self.attachDirectory()
            if self.observesApplications { self.reconcileObserver() }
            self.onChange()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    private func attachDirectory() {
        var directory = storageURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        guard directory != watchedDirectory else { return }
        directorySource?.cancel()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watchedDirectory = directory
        storageStamp = modificationDate()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watchedDirectory != self.storageURL.deletingLastPathComponent() {
                self.scheduleRefresh()
            }
            let changedAt = self.modificationDate()
            if self.storageStamp != changedAt {
                self.storageStamp = changedAt
                self.scheduleRefresh()
            }
            if self.directorySource?.data.contains(.rename) == true || self.directorySource?.data.contains(.delete) == true {
                self.watchedDirectory = nil
                self.scheduleRefresh()
            }
        }
        directorySource = source
        source.resume()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: storageURL.path)[.modificationDate]) as? Date
    }

    private func reconcileObserver() {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: TargetPromptMatcher.targetBundleIdentifier
        )
        guard AXIsProcessTrusted(), applications.count == 1, let application = applications.first else {
            detachObserver()
            return
        }
        if processID != application.processIdentifier {
            detachObserver()
            let element = AXUIElementCreateApplication(application.processIdentifier)
            var created: AXObserver?
            guard AXObserverCreate(application.processIdentifier, stateObserverCallback, &created) == .success,
                  let created else { return }
            processID = application.processIdentifier
            observer = created
            register(["AXWindowCreated", "AXFocusedWindowChanged", "AXFocusedUIElementChanged",
                      "AXLayoutChanged", "AXApplicationActivated"], on: element)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        // Electron emits layout changes on the web area rather than its NSWindow.
        // Refresh registrations when navigation replaces the renderer subtree.
        if let observer {
            for (element, name) in registrations {
                AXObserverRemoveNotification(observer, element, name as CFString)
            }
        }
        registrations.removeAll()
        register(["AXWindowCreated", "AXFocusedWindowChanged", "AXFocusedUIElementChanged",
                  "AXLayoutChanged", "AXApplicationActivated"], on: applicationElement)
        for window in AccessibilityElementReader().windowElements(in: applicationElement).prefix(8) {
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var index = 0
            while index < queue.count, index < 20 {
                let (element, depth) = queue[index]
                index += 1
                register(["AXLayoutChanged", "AXValueChanged", "AXFocusedUIElementChanged"], on: element)
                guard depth < 3 else { continue }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success,
                   let children = value as? [AXUIElement] {
                    queue.append(contentsOf: children.map { ($0, depth + 1) })
                }
            }
        }
    }

    private func register(_ names: [String], on element: AXUIElement) {
        guard let observer else { return }
        // Bound retained AX handles even during long-running Electron window churn.
        guard registrations.count < 96 else { return }
        for name in names where !registrations.contains(where: { CFEqual($0.0, element) && $0.1 == name }) {
            if AXObserverAddNotification(observer, element, name as CFString,
                                         Unmanaged.passUnretained(self).toOpaque()) == .success {
                registrations.append((element, name))
            }
        }
    }

    private func detachObserver() {
        if let observer {
            for (element, name) in registrations {
                AXObserverRemoveNotification(observer, element, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        registrations.removeAll()
        observer = nil
        processID = nil
    }
}
