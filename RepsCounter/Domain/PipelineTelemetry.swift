import Foundation
#if canImport(CoreMedia)
import CoreMedia
#endif
#if canImport(os)
import os
#endif

/// Opt-in for a single process launch (including optimized Instruments runs).
/// The telemetry clock never supplies a timestamp to the workout or its replay.
final class PipelineTelemetry: @unchecked Sendable {
    static let active: PipelineTelemetry? = {
        guard ProcessInfo.processInfo.environment["REPS_PIPELINE_TRACE"] == "1" else { return nil }
        let recorder = PipelineTelemetry()
        #if os(iOS)
        recorder.observeThermalState()
        #endif
        return recorder
    }()

    #if os(iOS)
    private var thermalObserver: NSObjectProtocol?

    private func observeThermalState() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.recordThermalState() }
        recordThermalState()
    }

    private func recordThermalState() {
        let reason: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: reason = "nominal"
        case .fair: reason = "fair"
        case .serious: reason = "serious"
        case .critical: reason = "critical"
        @unknown default: reason = "unknown"
        }
        record(.thermalState, reason: reason)
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }
    #endif

    enum Stage: String, Codable, Sendable {
        case cameraQuality, counterSampleSkipped, visionRequestStart, visionRequestEnd
        case cameraInput, avDropped, inactive, throttled, missingBuffer
        case visionStart, visionEnd, visionError, noPose, visionPose
        case streamEnqueue, streamReplaced, streamTerminated, serviceReceive
        case stale, wrongGeneration, wrongGeometry, outOfOrder, notRunning, futureFrame
        case deliveredPose, deliveredEmpty, processedPose, processedEmpty, skipped
        case analyzerStart, analyzerEnd, fsmStart, decision, reset, lifecycle, thermalState
        case stateUIStart, stateUIEnd, overlayStart, overlayEnd, replayInput
    }

    struct PTS: Codable, Sendable {
        let value: Int64
        let timescale: Int32
        let epoch: Int64
        let flags: UInt32
    }

    struct Identity: Codable, Sendable {
        let id: UInt64
        let generation: UInt64
        let camera: String
        let pts: PTS?
        let delegateHostSeconds: Double?
        let replaySeconds: Double?
        let captureHostSeconds: Double?
    }

    struct Leg: Codable, Equatable, Sendable {
        let hip, knee, ankle: Float?
        let rawAngle: Double?
        let issue: String?

        init(_ value: LegMeasurement) {
            hip = value.hipConfidence.flatMap { $0.isFinite ? $0 : nil }
            knee = value.kneeConfidence.flatMap { $0.isFinite ? $0 : nil }
            ankle = value.ankleConfidence.flatMap { $0.isFinite ? $0 : nil }
            rawAngle = value.angle
            issue = value.issue.map { String(describing: $0) }
        }
    }

    struct Decision: Codable, Equatable, Sendable {
        let left, right: Leg
        let previousLeg, selectedLeg: String?
        let phaseBeforeAnalysis, before, after, reason: String
        let streak: Int
        let ema, hipKneeRatio: Double?
        let movementReset, counted: Bool

        init(previousLeg: BodyLeg?, phaseBeforeAnalysis: SquatPhase, before: SquatPhase, analysis: PoseAnalysis,
             counter: SquatCounter, counted: Bool) {
            left = Leg(analysis.leftMeasurement)
            right = Leg(analysis.rightMeasurement)
            self.previousLeg = previousLeg?.rawValue
            selectedLeg = analysis.selectedLeg?.rawValue
            self.phaseBeforeAnalysis = phaseBeforeAnalysis.rawValue
            self.before = before.rawValue
            after = counter.phase.rawValue
            reason = String(describing: counter.decision)
            streak = counter.consecutiveFrames
            ema = analysis.smoothedAngle
            hipKneeRatio = analysis.hipKneeHeightRatio
            movementReset = analysis.requiresMovementReset
            self.counted = counted
        }
    }

    struct Event: Codable, Sendable {
        let sequence: UInt64
        let hostSeconds: Double
        let stage: Stage
        let frame: Identity?
        let elapsedMS, ageFromPTS_MS: Double?
        let reason: String?
        let decision: Decision?
        let replayControlSeconds: Double?
        var cameraQuality: CameraQuality? = nil

        var metricName: String {
            frame?.replaySeconds != nil || replayControlSeconds != nil ? "replay." + stage.rawValue : stage.rawValue
        }
    }

    struct Distribution: Codable {
        let samples: Int
        let p50, p95, p99: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double { sorted[Int(ceil(Double(sorted.count) * p)) - 1] }
            samples = sorted.count
            p50 = percentile(0.50)
            p95 = percentile(0.95)
            p99 = percentile(0.99)
        }
    }

    struct Snapshot: Codable {
        let traceVersion: Int
        let traceID: UUID
        let capacity: Int
        let overwritten: UInt64
        let totals: [String: UInt64]
        let elapsedMS, ageFromPTS_MS: [String: Distribution]
        let hz: [String: Double]
        let events: [Event]
    }

    struct Span {
        let start: Double
        #if canImport(os)
        let name: StaticString
        let interval: OSSignpostIntervalState?
        #endif
    }

    struct Frame: Sendable {
        let recorder: PipelineTelemetry
        let identity: Identity
        let inputTime: Double

        func begin(_ name: StaticString, _ stage: Stage, since: Double? = nil) -> Span {
            let start = mark(stage, since: since)
            #if canImport(os)
            let poster = recorder.signposter
            let interval = poster.isEnabled
                ? poster.beginInterval(name, id: poster.makeSignpostID(), "frame=\(identity.id)") : nil
            return Span(start: start, name: name, interval: interval)
            #else
            return Span(start: start)
            #endif
        }

        func end(_ span: Span?, _ stage: Stage, decision: @autoclosure () -> Decision? = nil) {
            guard let span else { return }
            #if canImport(os)
            if let interval = span.interval { recorder.signposter.endInterval(span.name, interval) }
            #endif
            recorder.record(stage, frame: identity, since: span.start, decision: decision())
        }

        @discardableResult
        func mark(_ stage: Stage, since: Double? = nil, reason: String? = nil) -> Double {
            recorder.record(stage, frame: identity, since: since, reason: reason)
        }
    }

    let traceID = UUID()
    private let clock: @Sendable () -> Double
    private let lock = NSLock()
    private let capacity: Int
    private var ring: [Event] = []
    private var sequence: UInt64 = 0
    private var lastFrameID: UInt64 = 0
    private var totals: [String: UInt64] = [:]
    #if canImport(os)
    private let signposter = OSSignposter(subsystem: "RepsCounter", category: "PosePipeline")
    #endif

    init(capacity: Int = 8192, clock: @escaping @Sendable () -> Double = { PipelineTelemetry.hostNow() }) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.clock = clock
        ring.reserveCapacity(capacity)
    }

    static func hostNow() -> Double {
        #if canImport(CoreMedia)
        return CMClockGetTime(CMClockGetHostTimeClock()).seconds
        #else
        return Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        #endif
    }

    func frame(generation: UInt64, camera: String, pts: PTS?, captureHostSeconds: Double?,
               stage: Stage = .cameraInput, reason: String? = nil,
               delegateHostSeconds: Double? = nil, replaySeconds: Double? = nil) -> Frame {
        lock.lock()
        lastFrameID += 1
        let identity = Identity(id: lastFrameID, generation: generation, camera: camera,
                                pts: pts, delegateHostSeconds: delegateHostSeconds, replaySeconds: replaySeconds, captureHostSeconds: captureHostSeconds)
        let time = append(stage, frame: identity, since: delegateHostSeconds, reason: reason, replayControlSeconds: nil, decision: { nil })
        lock.unlock()
        return Frame(recorder: self, identity: identity, inputTime: time)
    }

    @discardableResult
    func record(_ stage: Stage, frame: Identity? = nil, since: Double? = nil, cameraQuality: CameraQuality? = nil,
                reason: String? = nil, replayControlSeconds: Double? = nil, decision: @autoclosure () -> Decision? = nil) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return append(stage, frame: frame, since: since, reason: reason, replayControlSeconds: replayControlSeconds, cameraQuality: cameraQuality, decision: decision)
    }

    // Capture sequence and clock under the same lock on both queues.
    private func append(_ stage: Stage, frame: Identity?, since: Double?, reason: String?, replayControlSeconds: Double?, cameraQuality: CameraQuality? = nil, decision: () -> Decision?) -> Double {
        let now = clock()
        func duration(_ start: Double?) -> Double? {
            guard let start, start.isFinite, start <= now else { return nil }
            return (now - start) * 1000
        }
        var event = Event(sequence: sequence, hostSeconds: now, stage: stage, frame: frame,
                      elapsedMS: duration(since), ageFromPTS_MS: duration(frame?.captureHostSeconds),
                      reason: reason, decision: decision(), replayControlSeconds: replayControlSeconds)
        event.cameraQuality = cameraQuality
        if ring.count < capacity {
            ring.append(event)
        } else {
            ring[Int(sequence % UInt64(capacity))] = event
        }
        sequence += 1
        totals[event.metricName, default: 0] += 1
        #if canImport(os)
        if signposter.isEnabled {
            signposter.emitEvent("PosePipeline", "frame=\(frame?.id ?? 0) stage=\(stage.rawValue, privacy: .public)")
        }
        #endif
        return now
    }

    func export() async throws -> URL {
        try await Task.detached(priority: .utility) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepsCounter-Pipeline-\(UUID().uuidString).json")
            let data = try JSONEncoder().encode(self.snapshot())
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    /// Only the manual exporter and tests take snapshots. Sorting never runs on capture.
    func snapshot() -> Snapshot {
        lock.lock()
        let end = sequence
        let retained = ring.count
        let counts = totals
        lock.unlock()

        // Copy in bounded batches so exporting a large trace does not hold up a camera callback.
        var events: [Event] = []
        events.reserveCapacity(retained)
        var cursor = end - UInt64(retained)
        while cursor < end {
            let limit = min(end, cursor + 64)
            lock.lock()
            while cursor < limit {
                let event = ring[Int(cursor % UInt64(capacity))]
                if event.sequence == cursor { events.append(event) }
                cursor += 1
            }
            lock.unlock()
        }
        let overwritten = end - UInt64(events.count)
        let groups = Dictionary(grouping: events, by: \.metricName)
        let elapsed = groups.compactMapValues { Distribution($0.compactMap(\.elapsedMS)) }
        let ages = groups.compactMapValues { Distribution($0.compactMap(\.ageFromPTS_MS)) }
        let rates = groups.compactMapValues { rows -> Double? in
            guard let first = rows.first, let last = rows.last, last.hostSeconds > first.hostSeconds else { return nil }
            return Double(rows.count - 1) / (last.hostSeconds - first.hostSeconds)
        }
        return Snapshot(traceVersion: 2, traceID: traceID, capacity: capacity, overwritten: overwritten,
                        totals: counts, elapsedMS: elapsed, ageFromPTS_MS: ages, hz: rates, events: events)
    }
}


extension PipelineTelemetry {
    struct CameraQuality: Codable, Sendable {
        let width, height: Int
        let requestedResolution: Int
        let targetVisionHz: Int
        let rotationAngle: Double
        let mirrored: Bool
        let orientation: String
        let confidences: [String: Float]
        let buildSHA, sourceState: String
        var patchSHA: String? = nil
        var previewMirrored: Bool? = nil
        var regionOfInterest: String? = nil
    }
}

#if DEBUG
struct CameraQualityConfiguration: Equatable, Sendable {
    enum Resolution: Int, CaseIterable { case hd720 = 720, hd1080 = 1080 }
    enum VisionRate: Int, CaseIterable { case hz10 = 10, hz15 = 15, hz30 = 30 }
    var resolution = Resolution.hd720
    var visionRate = VisionRate.hz10
    static let baseline = Self()
    var analysisInterval: Double {
        visionRate == .hz10 ? 0.08 : (visionRate == .hz15 ? 0.066 : 0.033)
    }
    var analysisDuration: Duration {
        .milliseconds(visionRate == .hz10 ? 80 : (visionRate == .hz15 ? 66 : 33))
    }
    static let counterInterval = Duration.milliseconds(80)
    static func acceptsCounter(elapsed: Duration) -> Bool { elapsed >= counterInterval }
    var limitsCounterCadence: Bool { visionRate != .hz10 }
    func accepts(elapsed: Double) -> Bool { elapsed.isFinite && elapsed >= analysisInterval }
    func supported(by resolutions: Set<Int>) -> Bool { resolutions.contains(resolution.rawValue) }
}
#endif

#if DEBUG
final class CameraQualitySelection: @unchecked Sendable {
    private static let shared = CameraQualitySelection()
    private let lock = NSLock()
    private var value = CameraQualityConfiguration.baseline
    static var current: CameraQualityConfiguration {
        get {
            shared.lock.lock()
            defer { shared.lock.unlock() }
            return shared.value
        }
        set {
            shared.lock.lock()
            shared.value = newValue
            shared.lock.unlock()
        }
    }
    static let build: (sha: String, state: String, patch: String) = {
        guard let url = Bundle.main.url(forResource: "CameraQualityBuild", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ("unknown", "unknown", "unknown") }
        let lines = text.split(separator: "\n").map(String.init)
        return (lines.first ?? "unknown", lines.dropFirst().first ?? "unknown", lines.dropFirst(2).first ?? "unknown")
    }()
}

#endif
