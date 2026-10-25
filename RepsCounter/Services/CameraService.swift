import Foundation

enum CameraState: Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case stopped
    case permissionDenied
    case interrupted
    case failed(String)
    case finished
}

@MainActor
final class CameraService {
    enum CameraError: LocalizedError {
        case cameraUnavailable
        case configurationFailed

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable: return "Камера временно недоступна. Попробуйте ещё раз."
            case .configurationFailed: return "Не удалось настроить видеопоток."
            }
        }
    }

    var onStateChange: ((CameraState) -> Void)?
    var onPose: ((BodyPose?) -> Void)?
    private(set) var state: CameraState = .idle
    var previewSource: CameraPreviewSource? { capture.previewSource }

    private let permission: any CameraAuthorizing
    private let capture: any CameraCapturing
    private let frameTime: @MainActor () -> ContinuousClock.Instant
    private var generation: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var permissionTask: Task<Bool, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var lastFrameTime: ContinuousClock.Instant?

    init(
        permission: (any CameraAuthorizing)? = nil,
        capture: any CameraCapturing = CameraCapture(),
        frameTime: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.permission = permission ?? CameraPermission()
        self.capture = capture
        self.frameTime = frameTime
        let frames = capture.frames
        let events = capture.events
        frameTask = Task { @MainActor [weak self] in
            for await frame in frames {
                guard !Task.isCancelled else { return }
                self?.receive(frame)
            }
        }
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    deinit {
        permissionTask?.cancel()
        startTask?.cancel()
        frameTask?.cancel()
        eventTask?.cancel()
        let capture = capture
        if shutdownTask == nil { Task { await capture.shutdown() } }
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        if let startTask { return startTask }
        guard state != .running, state != .finished else { return Task {} }
        generation += 1
        let currentGeneration = generation
        let permission = permission
        let capture = capture
        let authorization = permission.status
        if authorization == .notDetermined, permissionTask == nil {
            permissionTask = Task { @MainActor in
                guard !Task.isCancelled else { return false }
                return await permission.requestAccess()
            }
        }
        let permissionRequest = permissionTask
        setState(authorization == .notDetermined ? .requestingPermission : .starting)
        let operation = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                defer { self?.completeStart(generation: currentGeneration) }
                let authorized: Bool
                switch authorization {
                case .authorized: authorized = true
                case .notDetermined: authorized = await permissionRequest?.value ?? false
                case .denied: authorized = false
                }
                guard !Task.isCancelled, self?.generation == currentGeneration else { return }
                guard authorized else {
                    self?.setState(.permissionDenied)
                    return
                }
                self?.setState(.starting)
                do {
                    try await capture.start(generation: currentGeneration)
                    guard !Task.isCancelled, self?.generation == currentGeneration else {
                        await capture.stop(generation: currentGeneration)
                        return
                    }
                    self?.setState(.running)
                } catch is CancellationError {
                    if self?.generation == currentGeneration { self?.setState(.stopped) }
                } catch {
                    if self?.generation == currentGeneration { self?.setState(.failed(error.localizedDescription)) }
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelStart(generation: currentGeneration)
                }
            }
        }
        startTask = operation
        return operation
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        guard state != .finished else { return Task {} }
        invalidateStart()
        setState(.stopped)
        let capture = capture
        let currentGeneration = generation
        return Task { await capture.stop(generation: currentGeneration) }
    }

    @discardableResult
    func finish() -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        guard state != .finished else { return Task {} }
        invalidateStart()
        permissionTask?.cancel()
        permissionTask = nil
        frameTask?.cancel()
        eventTask?.cancel()
        frameTask = nil
        eventTask = nil
        setState(.finished)
        let capture = capture
        let operation = Task { await capture.shutdown() }
        shutdownTask = operation
        return operation
    }

    func refreshAuthorization() {
        guard state != .finished, state != .running, startTask == nil else { return }
        if permission.status == .denied {
            setState(.permissionDenied)
        } else if state == .permissionDenied {
            setState(.stopped)
        }
    }

    private func completeStart(generation completedGeneration: UInt64) {
        guard generation == completedGeneration else { return }
        startTask = nil
        permissionTask = nil
        if Task.isCancelled, state == .starting || state == .requestingPermission { setState(.stopped) }
    }

    private func cancelStart(generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration,
              state == .starting || state == .requestingPermission || state == .running else { return }
        stop()
    }

    private func invalidateStart() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        lastFrameTime = nil
    }

    private func setState(_ state: CameraState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }

    func receive(_ frame: CameraFrame) {
        guard state == .running, frame.generation == generation,
              frame.capturedAt <= frameTime(),
              frame.capturedAt.duration(to: frameTime()) <= .milliseconds(250),
              lastFrameTime.map({ frame.capturedAt > $0 }) ?? true else { return }
        lastFrameTime = frame.capturedAt
        onPose?(frame.pose)
    }

    func receive(_ event: CameraSessionEvent) {
        switch event {
        case .interruptionEnded:
            if state == .interrupted { setState(.stopped) }
        case .interrupted, .runtimeError:
            guard state == .running || state == .starting else { return }
            invalidateStart()
            if case .runtimeError(let message) = event { setState(.failed(message)) }
            else { setState(.interrupted) }
            let capture = capture
            let currentGeneration = generation
            Task { await capture.stop(generation: currentGeneration) }
        }
    }
}
