import AppKit
import Foundation
import TypelessQuietCore

@MainActor
protocol TypelessClientControlling {
    func restart(completion: @escaping (Result<Void, Error>) -> Void)
    func open() -> Bool
}

enum TypelessClientControlError: LocalizedError {
    case unavailable
    case busy
    case refused
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法定位唯一的 Typeless 官方客户端"
        case .busy: "Typeless 正在录音或处理转录，请结束后再重启"
        case .refused: "Typeless 暂未同意退出；请在官方应用处理提示后重试"
        case .timedOut: "Typeless 未在时限内退出，未强制结束进程；请手动退出后重新打开"
        }
    }
}

/// Runs only from an explicit user action. Never forces termination or edits app data.
@MainActor
final class TypelessClientController: NSObject, TypelessClientControlling {
    private var targetPID: pid_t?
    private var targetURL: URL?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeout: DispatchWorkItem?

    func open() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: TargetPromptMatcher.targetBundleIdentifier
        ) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func restart(completion: @escaping (Result<Void, Error>) -> Void) {
        guard self.completion == nil else { return }
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: TargetPromptMatcher.targetBundleIdentifier
        )
        guard apps.count == 1, let app = apps.first, let url = app.bundleURL else {
            completion(.failure(TypelessClientControlError.unavailable))
            return
        }
        self.completion = completion
        targetPID = app.processIdentifier
        targetURL = url
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didTerminate),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(TypelessClientControlError.timedOut))
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        if !app.terminate() { finish(.failure(TypelessClientControlError.refused)) }
    }

    @objc private func didTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == targetPID, let targetURL else { return }
        timeout?.cancel()
        timeout = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: targetURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                if let error {
                    self?.finish(.failure(error))
                } else if app?.bundleIdentifier == TargetPromptMatcher.targetBundleIdentifier {
                    self?.finish(.success(()))
                } else {
                    self?.finish(.failure(TypelessClientControlError.unavailable))
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        targetPID = nil
        targetURL = nil
        let callback = completion
        completion = nil
        callback?(result)
    }
}
