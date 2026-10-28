//
//  CameraCapture.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

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
    let position: CameraPosition
    let rotationAngle: CGFloat

    init(
        generation: UInt64, pose: BodyPose?, capturedAt: ContinuousClock.Instant,
        position: CameraPosition = .front, rotationAngle: CGFloat = 90
    ) {
        self.generation = generation
        self.pose = pose
        self.capturedAt = capturedAt
        self.position = position
        self.rotationAngle = rotationAngle
    }
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
    func start(generation: UInt64, position: CameraPosition) async throws -> CameraConfiguration
    func stop(generation: UInt64) async
    func shutdown() async
    #if DEBUG
    var experiment: PoseExperimentCapture? { get }
    #endif
}

#if DEBUG
extension CameraCapturing {
    var experiment: PoseExperimentCapture? { nil }
}
#endif

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
        #if DEBUG
        var experiment: PoseExperimentCapture?
        var frameSequence: UInt64 = 0
        #endif
    }

    private let generation: UInt64
    private let position: CameraPosition
    private let rotationAngle: CGFloat
    private let continuation: AsyncStream<CameraFrame>.Continuation
    private let processing = OSAllocatedUnfairLock(uncheckedState: FrameState())

    init(
        generation: UInt64, position: CameraPosition, rotationAngle: CGFloat,
        continuation: AsyncStream<CameraFrame>.Continuation
    ) {
        self.generation = generation
        self.position = position
        self.rotationAngle = rotationAngle
        self.continuation = continuation
    }

    func invalidate() {
        processing.withLock { state in state.isActive = false }
    }

    #if DEBUG
    func attachExperiment(_ experiment: PoseExperimentCapture) {
        processing.withLock { $0.experiment = experiment }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processing.withLock { $0.experiment?.noteSourceFrame(dropped: true) }
    }
    #endif

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processing.withLockUnchecked { state in
            let capturedAt = ContinuousClock.now
            guard state.isActive else { return }
            #if DEBUG
            state.frameSequence += 1
            state.experiment?.noteSourceFrame()
            #endif
            if let previousTime = state.previousAnalysisTime,
               previousTime.duration(to: capturedAt) < .milliseconds(80) { return }
            state.previousAnalysisTime = capturedAt
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pose = state.detector.detect(pixelBuffer: pixelBuffer, rotationAngle: rotationAngle)
            continuation.yield(CameraFrame(
                generation: generation, pose: pose, capturedAt: capturedAt,
                position: position, rotationAngle: rotationAngle
            ))
            #if DEBUG
            let metadata = ExperimentFrameMetadata(
                identity: ExperimentFrameIdentity(generation: generation, sequence: state.frameSequence),
                timestamp: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                receivedAt: capturedAt, position: position, rotationAngle: rotationAngle,
                orientation: PoseGeometry.visionOrientation.rawValue, inputMirrored: false, depthDataProvided: false
            )
            state.experiment?.submit(
                sampleBuffer: sampleBuffer, pose: pose, metadata: metadata,
                planarLatency: capturedAt.duration(to: .now).experimentSeconds
            )
            #endif
        }
    }
}

actor CameraCapture: CameraCapturing {
    #if DEBUG
    nonisolated let experiment: PoseExperimentCapture? = PoseExperimentCapture()
    #endif
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
    private var cameraInput: AVCaptureDeviceInput?
    private var cameraPosition: CameraPosition?
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

    func start(generation: UInt64, position: CameraPosition) throws -> CameraConfiguration {
        try Task.checkCancellation()
        guard !isShutdown, generation >= latestGeneration else { throw CancellationError() }
        latestGeneration = generation
        let requiresConfiguration = cameraPosition != position || cameraInput == nil || output == nil
        if requiresConfiguration { stopSession() }
        do {
            let rotationAngle: CGFloat
            if requiresConfiguration { rotationAngle = try configure(position: position) }
            else { rotationAngle = try configureVideoConnection() }
            try Task.checkCancellation()
            if !session.isRunning { session.startRunning() }
            try Task.checkCancellation()
            guard session.isRunning else { throw CameraService.CameraError.cameraUnavailable }
            processor?.invalidate()
            output?.setSampleBufferDelegate(nil, queue: nil)
            frameQueue.sync {}
            try Task.checkCancellation()
            let processor = CameraFrameProcessor(
                generation: generation, position: position, rotationAngle: rotationAngle,
                continuation: frameContinuation
            )
            self.processor = processor
            #if DEBUG
            if let experiment {
                experiment.configure(generation: generation, position: position, rotationAngle: rotationAngle)
                processor.attachExperiment(experiment)
            }
            #endif
            output?.setSampleBufferDelegate(processor, queue: frameQueue)
            try Task.checkCancellation()
            return CameraConfiguration(position: position, rotationAngle: rotationAngle)
        } catch {
            stopSession()
            throw error
        }
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
        #if DEBUG
        experiment?.shutdown()
        #endif
        notifications.stop()
        frameContinuation.finish()
        eventContinuation.finish()
    }

    private func stopSession() {
        #if DEBUG
        experiment?.suspend()
        #endif
        processor?.invalidate()
        output?.setSampleBufferDelegate(nil, queue: nil)
        processor = nil
        if session.isRunning { session.stopRunning() }
        frameQueue.sync {}
    }

    private func configure(position: CameraPosition) throws -> CGFloat {
        let devicePosition: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: devicePosition) else {
            throw CameraService.CameraError.cameraUnavailable
        }
        let replacementInput = try AVCaptureDeviceInput(device: device)
        try Task.checkCancellation()
        let previousInput = cameraInput
        let previousPosition = cameraPosition
        let previousOutput = output
        try replaceInput(replacementInput, position: position)
        do {
            return try configureVideoConnection()
        } catch {
            session.beginConfiguration()
            if let cameraInput { session.removeInput(cameraInput) }
            if previousOutput == nil, let output { session.removeOutput(output) }
            output = previousOutput
            restoreInput(previousInput, position: previousPosition)
            session.commitConfiguration()
            throw error
        }
    }

    private func replaceInput(_ replacementInput: AVCaptureDeviceInput, position: CameraPosition) throws {
        let previousInput = cameraInput
        let previousPosition = cameraPosition
        let candidateOutput = output ?? AVCaptureVideoDataOutput()
        candidateOutput.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        if let previousInput { session.removeInput(previousInput) }
        cameraInput = nil
        cameraPosition = nil
        guard session.canAddInput(replacementInput), output != nil || session.canAddOutput(candidateOutput) else {
            restoreInput(previousInput, position: previousPosition)
            throw CameraService.CameraError.configurationFailed
        }
        session.addInput(replacementInput)
        if output == nil { session.addOutput(candidateOutput) }
        cameraInput = replacementInput
        cameraPosition = position
        output = candidateOutput
    }

    private func restoreInput(_ previousInput: AVCaptureDeviceInput?, position: CameraPosition?) {
        cameraInput = nil
        cameraPosition = nil
        guard let previousInput, let position, session.canAddInput(previousInput) else { return }
        session.addInput(previousInput)
        cameraInput = previousInput
        cameraPosition = position
    }

    private func configureVideoConnection() throws -> CGFloat {
        guard let connection = output?.connection(with: .video), let cameraInput else {
            throw CameraService.CameraError.configurationFailed
        }
        let requestedAngle: CGFloat
        if #available(iOS 27.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: cameraInput.device, previewLayer: nil)
            requestedAngle = coordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)
        } else {
            requestedAngle = try legacyPortraitAngle(connection: connection)
        }
        guard requestedAngle.isFinite else { throw CameraService.CameraError.configurationFailed }
        let remainder = requestedAngle.truncatingRemainder(dividingBy: 360)
        let normalized = remainder < 0 ? remainder + 360 : remainder
        let quarterTurn = (normalized / 90).rounded() * 90
        let rotationAngle = quarterTurn.truncatingRemainder(dividingBy: 360)
        guard abs(normalized - quarterTurn) < 0.001,
              connection.isVideoRotationAngleSupported(rotationAngle) else {
            throw CameraService.CameraError.configurationFailed
        }
        connection.videoRotationAngle = rotationAngle
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return rotationAngle
    }

    @available(iOS, introduced: 17.0, deprecated: 17.0, obsoleted: 27.0, message: "Fixed-portrait compatibility for iOS 17–26; static device-relative rotation requires iOS 27.")
    private func legacyPortraitAngle(connection: AVCaptureConnection) throws -> CGFloat {
        guard connection.isVideoOrientationSupported else { throw CameraService.CameraError.configurationFailed }
        connection.videoOrientation = .portrait
        return connection.videoRotationAngle
    }
}
