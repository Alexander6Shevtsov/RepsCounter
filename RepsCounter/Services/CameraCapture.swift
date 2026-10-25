import AVFoundation
import Foundation
import os

enum CameraAuthorization {
    case authorized
    case notDetermined
    case denied
}

@MainActor
protocol CameraAuthorizing {
    var status: CameraAuthorization { get }
    func requestAccess() async -> Bool
}

struct CameraPermission: CameraAuthorizing {
    var status: CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

struct CameraFrame: Sendable {
    let generation: UInt64
    let pose: BodyPose?
    let capturedAt: ContinuousClock.Instant
}

enum CameraSessionEvent: Sendable, Equatable {
    case interrupted
    case interruptionEnded
    case runtimeError(String)
}

protocol CameraCapturing: Sendable {
    var frames: AsyncStream<CameraFrame> { get }
    var events: AsyncStream<CameraSessionEvent> { get }
    var previewSource: CameraPreviewSource? { get }
    func start(generation: UInt64) async throws
    func stop(generation: UInt64) async
    func shutdown() async
}

final class CameraPreviewSource: @unchecked Sendable {
    private let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }

    @MainActor
    func connect(to previewLayer: AVCaptureVideoPreviewLayer) {
        previewLayer.session = session
    }
}

final class CameraSessionNotifications: Sendable {
    private struct ObserverState {
        var tokens: [NSObjectProtocol] = []
    }

    private let center: NotificationCenter
    private let observers = OSAllocatedUnfairLock(uncheckedState: ObserverState())

    init(session: AVCaptureSession, center: NotificationCenter, continuation: AsyncStream<CameraSessionEvent>.Continuation) {
        self.center = center
        observers.withLockUnchecked { state in
            state.tokens = [
                center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { _ in
                    continuation.yield(.interrupted)
                },
                center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { _ in
                    continuation.yield(.interruptionEnded)
                },
                center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { notification in
                    let failure = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                    continuation.yield(.runtimeError(failure?.localizedDescription ?? "Временная ошибка камеры."))
                }
            ]
        }
    }

    deinit {
        stop()
    }

    func stop() {
        observers.withLock { state in
            for token in state.tokens { center.removeObserver(token) }
            state.tokens.removeAll()
        }
    }
}

private final class CameraFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    private struct FrameState {
        let detector = PoseDetector()
        var isActive = true
        var previousAnalysisTime: ContinuousClock.Instant?
    }

    private let generation: UInt64
    private let continuation: AsyncStream<CameraFrame>.Continuation
    private let processing = OSAllocatedUnfairLock(uncheckedState: FrameState())

    init(generation: UInt64, continuation: AsyncStream<CameraFrame>.Continuation) {
        self.generation = generation
        self.continuation = continuation
    }

    func invalidate() {
        processing.withLock { state in state.isActive = false }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processing.withLockUnchecked { state in
            let capturedAt = ContinuousClock.now
            guard state.isActive else { return }
            if let previousTime = state.previousAnalysisTime,
               previousTime.duration(to: capturedAt) < .milliseconds(80) { return }
            state.previousAnalysisTime = capturedAt
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pose = state.detector.detect(pixelBuffer: pixelBuffer)
            continuation.yield(CameraFrame(generation: generation, pose: pose, capturedAt: capturedAt))
        }
    }
}

actor CameraCapture: CameraCapturing {
    nonisolated let frames: AsyncStream<CameraFrame>
    nonisolated let events: AsyncStream<CameraSessionEvent>
    nonisolated let previewSource: CameraPreviewSource?
    private nonisolated let sessionQueue = DispatchSerialQueue(label: "repscounter.camera.session")
    nonisolated var unownedExecutor: UnownedSerialExecutor { sessionQueue.asUnownedSerialExecutor() }

    private let session: AVCaptureSession
    private let frameQueue = DispatchQueue(label: "repscounter.camera.frames")
    private let frameContinuation: AsyncStream<CameraFrame>.Continuation
    private let eventContinuation: AsyncStream<CameraSessionEvent>.Continuation
    private let notifications: CameraSessionNotifications
    private var output: AVCaptureVideoDataOutput?
    private var processor: CameraFrameProcessor?
    private var latestGeneration: UInt64 = 0
    private var isShutdown = false

    init() {
        let session = AVCaptureSession()
        let frameStream = AsyncStream<CameraFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let eventStream = AsyncStream<CameraSessionEvent>.makeStream()
        self.session = session
        frames = frameStream.stream
        events = eventStream.stream
        frameContinuation = frameStream.continuation
        eventContinuation = eventStream.continuation
        previewSource = CameraPreviewSource(session: session)
        notifications = CameraSessionNotifications(session: session, center: .default, continuation: eventStream.continuation)
    }

    func start(generation: UInt64) throws {
        try Task.checkCancellation()
        guard !isShutdown, generation >= latestGeneration else { throw CancellationError() }
        latestGeneration = generation
        if output == nil { try configure() }
        try Task.checkCancellation()
        if !session.isRunning { session.startRunning() }
        do {
            try Task.checkCancellation()
            guard session.isRunning else { throw CameraService.CameraError.cameraUnavailable }
        } catch {
            if session.isRunning { session.stopRunning() }
            throw error
        }
        processor?.invalidate()
        let processor = CameraFrameProcessor(generation: generation, continuation: frameContinuation)
        self.processor = processor
        output?.setSampleBufferDelegate(processor, queue: frameQueue)
    }

    func stop(generation: UInt64) {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        stopSession()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        stopSession()
        notifications.stop()
        frameContinuation.finish()
        eventContinuation.finish()
    }

    private func stopSession() {
        processor?.invalidate()
        output?.setSampleBufferDelegate(nil, queue: nil)
        processor = nil
        if session.isRunning { session.stopRunning() }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraService.CameraError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CameraService.CameraError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        self.output = output
    }
}
