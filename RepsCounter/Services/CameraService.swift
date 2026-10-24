import AVFoundation
import Foundation

final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case permissionDenied
        case cameraUnavailable
        case configurationFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Разрешите доступ к камере в настройках iPhone."
            case .cameraUnavailable: return "Не удалось найти заднюю камеру."
            case .configurationFailed: return "Не удалось настроить видеопоток."
            }
        }
    }

    let captureSession = AVCaptureSession()
    var onPose: ((BodyPose?) -> Void)?

    private let sessionQueue = DispatchQueue(label: "repscounter.camera.session")
    private let frameQueue = DispatchQueue(label: "repscounter.camera.frames")
    private let detector = PoseDetector()
    private var isConfigured = false
    private var previousAnalysisTime: CFAbsoluteTime = 0

    func start() async throws {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }

        guard authorized else { throw CameraError.permissionDenied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    if !self.isConfigured { try self.configure() }
                    if !self.captureSession.isRunning { self.captureSession.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            throw CameraError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .hd1280x720
        guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
            throw CameraError.configurationFailed
        }
        captureSession.addInput(input)
        captureSession.addOutput(output)
        isConfigured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let currentTime = CFAbsoluteTimeGetCurrent()
        guard currentTime - previousAnalysisTime >= 0.08 else { return }
        previousAnalysisTime = currentTime
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onPose?(detector.detect(pixelBuffer: pixelBuffer))
    }
}
