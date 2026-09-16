import AppKit
import Foundation
import LocalAuthentication

struct AuthenticationResult {
    let decision: Decision
    var authMethod: AuthMethod { decision == .approved ? .biometricOrWatch : .none }
}

final class LockedResult<Value> {
    private let lock = NSLock()
    private var result: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func complete(_ value: Value) {
        lock.lock()
        if result == nil { result = value }
        lock.unlock()
    }
}

protocol AuthenticationSession: AnyObject {
    func start(
        request: AuthRequestBody,
        requireConfirmation: Bool,
        lifetime: RequestLifetime,
        completion: @escaping (AuthenticationResult) -> Void
    )
    func cancel()
}

func confirmationCancellationTimer(lifetime: RequestLifetime, onCancel: @escaping () -> Void) -> Timer {
    precondition(Thread.isMainThread)
    let timer = Timer(timeInterval: 0.025, repeats: true) { _ in
        if !lifetime.isActive { onCancel() }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    return timer
}

final class AuthenticationCoordinator {
    private let slot = DispatchSemaphore(value: 1)
    private let makeSession: () -> AuthenticationSession

    init(makeSession: @escaping () -> AuthenticationSession = { LocalAuthenticationSession() }) {
        self.makeSession = makeSession
    }

    func evaluate(request: AuthRequestBody, requireConfirmation: Bool, lifetime: RequestLifetime) throws -> AuthenticationResult {
        while slot.wait(timeout: .now() + .milliseconds(25)) != .success {
            try lifetime.check()
        }
        defer { slot.signal() }
        try lifetime.check()
        let session = makeSession()
        defer { session.cancel() }
        let result = LockedResult<AuthenticationResult>()
        let ready = DispatchSemaphore(value: 0)
        session.start(request: request, requireConfirmation: requireConfirmation, lifetime: lifetime) {
            result.complete($0)
            ready.signal()
        }
        while result.value == nil {
            try lifetime.check()
            _ = ready.wait(timeout: .now() + .milliseconds(25))
        }
        try lifetime.check()
        return result.value!
    }
}

final class LocalAuthenticationSession: AuthenticationSession {
    private let context = LAContext()

    func start(
        request: AuthRequestBody,
        requireConfirmation: Bool,
        lifetime: RequestLifetime,
        completion: @escaping (AuthenticationResult) -> Void
    ) {
        RunLoop.main.perform(inModes: [.default]) { [self] in
            guard lifetime.isActive else { return }
            if requireConfirmation && !MacosAuthAgent.showConfirmationAlert(for: request, lifetime: lifetime) {
                completion(AuthenticationResult(decision: .cancelled))
                return
            }
            guard lifetime.isActive else { return }
            context.localizedCancelTitle = "Use Linux Password"
            context.localizedFallbackTitle = ""
            let policy = MacosAuthAgent.authenticationPolicy()
            var error: NSError?
            guard context.canEvaluatePolicy(policy, error: &error) else {
                completion(AuthenticationResult(decision: .unavailable))
                return
            }
            guard lifetime.isActive else { return }
            context.evaluatePolicy(policy, localizedReason: MacosAuthAgent.localAuthenticationReason(for: request)) { success, error in
                let decision: Decision
                if success {
                    decision = .approved
                } else if let error = error as? LAError {
                    switch error.code {
                    case .userCancel, .systemCancel, .appCancel:
                        decision = .cancelled
                    case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .watchNotAvailable:
                        decision = .unavailable
                    default:
                        decision = .failed
                    }
                } else {
                    decision = .failed
                }
                completion(AuthenticationResult(decision: decision))
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func cancel() { context.invalidate() }
}
