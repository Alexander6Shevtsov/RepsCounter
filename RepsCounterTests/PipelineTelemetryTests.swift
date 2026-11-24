import Foundation
import XCTest
@testable import RepsCounter

final class PipelineTelemetryTests: XCTestCase {
    func testLatencyRateAndPTSUseSeparateClocks() throws {
        let clock = TelemetryTestClock()
        let recorder = PipelineTelemetry(capacity: 512, clock: { clock.now })
        let pts = PipelineTelemetry.PTS(value: 123456789, timescale: 60000, epoch: 7, flags: 1)
        for i in 1...100 {
            clock.now = Double(i)
            let frame = recorder.frame(generation: 8, camera: "back", pts: pts, captureHostSeconds: clock.now - 0.25)
            let span = frame.begin("Test Vision", .visionStart)
            clock.now += Double(i) / 1024
            frame.end(span, .visionEnd)
        }
        let snapshot = recorder.snapshot()
        let measurement = try XCTUnwrap(snapshot.elapsedMS["visionEnd"])
        XCTAssertEqual(measurement.samples, 100)
        XCTAssertEqual(measurement.p50, 50 * 1000.0 / 1024)
        XCTAssertEqual(measurement.p95, 95 * 1000.0 / 1024)
        XCTAssertEqual(measurement.p99, 99 * 1000.0 / 1024)
        XCTAssertEqual(snapshot.hz["visionStart"], 1)
        XCTAssertEqual(snapshot.ageFromPTS_MS["cameraInput"]?.p95, 250)
        XCTAssertEqual(snapshot.events.last?.frame?.pts?.value, pts.value)
        XCTAssertEqual(snapshot.events.last?.frame?.pts?.epoch, 7)
        XCTAssertEqual(snapshot.events.first?.frame?.id, 1)
        XCTAssertEqual(snapshot.events.last?.frame?.id, 100)
        XCTAssertEqual(snapshot.events.map(\.sequence), (0..<300).map(UInt64.init))
    }

    func testCountersSurviveEvictionAndMissingCaptureClock() throws {
        let telemetry = PipelineTelemetry(capacity: 3, clock: { 1 })
        let first = telemetry.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: nil)
        first.mark(.throttled)
        let dropped = telemetry.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: 2, stage: .avDropped)
        let next = telemetry.frame(generation: 2, camera: "back", pts: nil, captureHostSeconds: nil)
        next.mark(.noPose)
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.overwritten, 2)
        XCTAssertEqual(snapshot.totals["throttled"], 1)
        XCTAssertEqual(snapshot.totals["cameraInput"], 2)
        XCTAssertEqual(snapshot.totals["avDropped"], 1)
        XCTAssertEqual(snapshot.events.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(snapshot.events.map { $0.frame?.id }, [dropped.identity.id, next.identity.id, next.identity.id])
        XCTAssertTrue(snapshot.ageFromPTS_MS.isEmpty)
        XCTAssertTrue(snapshot.hz.isEmpty)
        let decoded = try JSONDecoder().decode(PipelineTelemetry.Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.traceVersion, 1)
        XCTAssertEqual(decoded.traceID, telemetry.traceID)
        XCTAssertEqual(decoded.events.map(\.stage), [.avDropped, .cameraInput, .noPose])
    }

    func testLiveAndReplayHaveSeparateMetricsAndTimedControlEvents() throws {
        let session = PoseReplaySession(schemaVersion: 1, events: [
            .init(seconds: 0.5, kind: .reset, pose: nil),
            .init(seconds: 0.6, kind: .pose, pose: nil)
        ], annotations: [])
        let recorder = PipelineTelemetry(clock: { 10 })
        recorder.record(.reset, reason: "pause")
        _ = try PoseReplayRunner.replay(session, telemetry: recorder)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.totals["reset"], 1)
        XCTAssertEqual(snapshot.totals["replay.reset"], 2)
        XCTAssertEqual(snapshot.totals["replay.decision"], 1)
        XCTAssertNil(snapshot.totals["decision"])
        XCTAssertEqual(snapshot.events[1].replayControlSeconds, 0.5)
        XCTAssertEqual(snapshot.events.last?.frame?.replaySeconds, 0.6)
        XCTAssertNil(snapshot.events.last?.frame?.pts)
    }

    func testConcurrentProducersKeepOrderedBoundedEventsAndLifetimeTotals() {
        let recorder = PipelineTelemetry(capacity: 32, clock: { 1 })
        DispatchQueue.concurrentPerform(iterations: 256) { i in
            let frame = recorder.frame(generation: UInt64(i % 2), camera: "front", pts: nil, captureHostSeconds: nil)
            frame.mark(.visionStart)
            if i.isMultiple(of: 16) {
                let partial = recorder.snapshot()
                XCTAssertLessThanOrEqual(partial.events.count, 32)
                XCTAssertEqual(partial.events.map(\.sequence), partial.events.map(\.sequence).sorted())
            }
        }
        let result = recorder.snapshot()
        XCTAssertEqual(result.events.map(\.sequence), (480..<512).map(UInt64.init))
        XCTAssertEqual(result.overwritten, 480)
        XCTAssertEqual(result.totals["cameraInput"], 256)
        XCTAssertEqual(result.totals["visionStart"], 256)
    }

    func testLegacyFormatsAndOptionalFrameLinkRoundTrip() throws {
        let v1 = #"{"schemaVersion":1,"events":[{"seconds":0,"kind":"pose"}],"annotations":[]}"#
        let v2 = #"{"schemaVersion":2,"initialState":{"phase":"lowered","pendingFrames":0,"selectedLeg":"left","smoothedAngle":90},"events":[{"seconds":0,"kind":"reset"}],"annotations":[]}"#
        for json in [v1, v2] {
            let session = try JSONDecoder().decode(PoseReplaySession.self, from: Data(json.utf8))
            XCTAssertNil(session.pipelineTraceID)
            XCTAssertNil(session.events.first?.pipelineFrameID)
            XCTAssertNoThrow(try PoseReplayRunner.replay(session))
        }
        var recorder = PoseReplayRecorder()
        let t = PipelineTelemetry()
        let frame = t.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: nil)
        XCTAssertTrue(recorder.start(at: 42))
        recorder.append(nil, at: 42, trace: frame)
        struct LegacyEvent: Decodable {
            let seconds: Double
            let kind: PoseReplayEventKind
        }
        struct LegacySession: Decodable {
            let schemaVersion: Int
            let events: [LegacyEvent]
        }
        let data = try recorder.encodedSession()
        let legacy = try JSONDecoder().decode(LegacySession.self, from: data)
        XCTAssertEqual(legacy.schemaVersion, 1)
        XCTAssertEqual(legacy.events.first?.kind, .pose)
        let session = try JSONDecoder().decode(PoseReplaySession.self, from: data)
        XCTAssertEqual(session.pipelineTraceID, t.traceID)
        XCTAssertEqual(session.events.first?.pipelineFrameID, frame.identity.id)
        XCTAssertEqual(session.events.first?.seconds, 0)
    }

    @MainActor
    func testLiveDecisionsAndReplayMatchWithAndWithoutTracingAcrossResets() throws {
        let time = TelemetryWorkoutClock()
        let t = PipelineTelemetry()
        let quiet = WorkoutViewModel(persistence: TelemetryStore(), timeSource: time, telemetry: nil)
        let observed = WorkoutViewModel(persistence: TelemetryStore(), timeSource: time, telemetry: t)
        XCTAssertTrue(quiet.startPoseReplayRecording())
        XCTAssertTrue(observed.startPoseReplayRecording())
        var observedFrames: [UInt64] = []
        for index in 0..<30 {
            if index == 23 {
                for model in [quiet, observed] { model.pause(); model.resume() }
            }
            let right = index >= 21
            let low = (5..<13).contains(index)
            let hip = JointPoint(location: low ? CGPoint(x: 0.2, y: 0.5) : CGPoint(x: 0.5, y: 0.8), confidence: 0.875)
            let knee = JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1)
            let ankle = JointPoint(location: CGPoint(x: 0.5, y: 0.2), confidence: 1)
            let pose = index == 25 ? nil : BodyPose(joints: [right ? .rightHip : .leftHip: hip,
                                                             right ? .rightKnee : .leftKnee: knee,
                                                             right ? .rightAnkle : .leftAnkle: ankle], aspectRatio: 1)
            time.currentTime += index == 27 ? 0.5 : 0.1
            let frame = t.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: nil)
            observedFrames.append(frame.identity.id)
            quiet.process(pose)
            observed.process(pose, trace: frame)
            XCTAssertEqual(quiet.latestDiagnostics?.phase, observed.latestDiagnostics?.phase)
            XCTAssertEqual(quiet.latestDiagnostics?.decision, observed.latestDiagnostics?.decision)
            XCTAssertEqual(quiet.latestDiagnostics?.analysis?.smoothedAngle, observed.latestDiagnostics?.analysis?.smoothedAngle)
        }
        let events = t.snapshot().events
        XCTAssertEqual(events.filter { $0.stage == .decision }.compactMap { $0.frame?.id }, observedFrames)
        let live = events.compactMap(\.decision)
        XCTAssertEqual(live.filter(\.counted).count, 1)
        XCTAssertEqual(live.first?.left.hip, 0.875)
        XCTAssertNil(live.first?.right.ankle)
        XCTAssertEqual(live[21].previousLeg, "left")
        XCTAssertEqual(live[21].selectedLeg, "right")
        XCTAssertEqual(events.filter { $0.stage == .reset }.compactMap(\.reason),
                       ["legChanged", "pause", "resume", "measurementLost", "observationGap"])
        let firstFrame = events.filter { $0.frame?.id == observedFrames.first }
        XCTAssertEqual(firstFrame.map(\.stage), [.cameraInput, .processedPose, .analyzerStart, .analyzerEnd,
                                                .fsmStart, .decision, .stateUIStart, .stateUIEnd])
        let quietData = try XCTUnwrap(quiet.stopPoseReplayRecording())
        let tracedData = try XCTUnwrap(observed.stopPoseReplayRecording())
        let quietSession = try JSONDecoder().decode(PoseReplaySession.self, from: quietData)
        let session = try JSONDecoder().decode(PoseReplaySession.self, from: tracedData)
        let replayTrace = PipelineTelemetry()
        let replay = try PoseReplayRunner.replay(session, telemetry: replayTrace)
        let reference = try PoseReplayRunner.replay(quietSession)
        XCTAssertEqual(reference.countedAtSeconds, replay.countedAtSeconds)
        XCTAssertEqual(reference.depthSamples.map(\.kneeAngle), replay.depthSamples.map(\.kneeAngle))
        XCTAssertEqual(reference.depthSamples.map(\.phase), replay.depthSamples.map(\.phase))
        XCTAssertEqual(replayTrace.snapshot().events.compactMap(\.decision), live)
        XCTAssertTrue(replayTrace.snapshot().ageFromPTS_MS.isEmpty)
        quiet.finish()
        observed.finish()
    }
}

private final class TelemetryTestClock: @unchecked Sendable {
    // Accessed synchronously by the test and its injected closure.
    var now = 0.0
}

@MainActor private final class TelemetryWorkoutClock: WorkoutTimeSource {
    var currentTime = 1.0
    let date = Date(timeIntervalSince1970: 1)
}

@MainActor private final class TelemetryStore: WorkoutStoring {
    func save(_ summary: WorkoutSummary) throws {}
    func history() throws -> [WorkoutSummary] { [] }
}
