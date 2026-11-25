#if DEBUG
import Foundation

struct PoseReplaySquatCycle {
    enum Phase: String {
        case seekingStanding, standing, descending, lowered, returning, insufficientData
    }

    enum Reason: String {
        case seekingStance, standing, descent, awaitingDepth, bilateralDepth, unilateralDepth
        case sustainedDepth, holdingDepth, missingJoints, insufficientDepth, conflictingLegs, movingSupport, changedGeometry
        case interrupted, expired, repeatedTimestamp, reset, renewedDescent, returning, counted
    }

    struct Step: Equatable {
        let phase: Phase
        let reason: Reason
        let counted: Bool
    }

    private typealias Observation = PoseReplayDepthAudit.KneeObservation
    private typealias Limits = PoseReplayOcclusionRecovery
    private static let thresholds = SquatCounter()
    private static let bentAngle = (thresholds.standingThreshold + thresholds.loweredThreshold) / 2
    private static let minimumDwell = Limits.continuity / 4

    private struct Leg {
        var observation: Observation?
        var ema: Double?
        var lastSeen: Double?
        var reference: Observation?
        var calibratedAt: Double?
        var standingSince: Double?

        mutating func update(_ value: Observation?, at time: Double) {
            observation = value
            guard let value else {
                standingSince = nil
                return
            }
            if let lastSeen, time - lastSeen > Limits.maxOcclusion {
                reference = nil
                calibratedAt = nil
            }
            if let lastSeen, let previous = ema, time - lastSeen <= Limits.continuity {
                let retention = pow(0.65, (time - lastSeen) / 0.1)
                ema = previous * retention + value.kneeAngle * (1 - retention)
            } else {
                ema = value.kneeAngle
                standingSince = nil
            }
            lastSeen = time
        }

        mutating func calibrate(at time: Double) {
            guard let observation, observation.hipAnkleHeight > 0,
                  observation.kneeAngle >= thresholds.standingThreshold else {
                standingSince = nil
                return
            }
            if standingSince == nil { standingSince = time }
            if let standingSince, time - standingSince >= minimumDwell {
                reference = observation
                calibratedAt = time
            }
        }

        var drop: Double? {
            guard let observation, let reference else { return nil }
            return 1 - observation.hipAnkleHeight / reference.hipAnkleHeight
        }

        var upright: Bool {
            (observation?.kneeAngle ?? 0) >= thresholds.standingThreshold
        }

        var compatibleWithStance: Bool {
            guard let observation else { return true }
            return observation.kneeAngle >= bentAngle && (drop ?? 0) <= 1 - Limits.standingHeight
        }

        var strict: Bool {
            guard let value = observation, let drop else { return false }
            return Limits.passesDepth(value) && drop >= Limits.minimumDrop
        }

        var supportsDepth: Bool {
            guard let value = observation, let drop else { return false }
            return strict || (value.kneeAngle <= bentAngle && drop >= Limits.strongDrop)
        }

        func footMoved(_ point: PoseReplayPoint?, aspect: Double) -> Bool {
            guard let reference, let point, (0.5...1).contains(point.confidence) else { return false }
            return hypot(point.horizontalPosition * aspect - reference.ankle.x,
                         point.verticalPosition - reference.ankle.y) > Limits.supportTolerance * reference.hipAnkleHeight
        }
    }

    private struct Bottom {
        private struct Sample {
            let time: Double
            let leftStrict, rightStrict: Bool
            let leftSupport, rightSupport: Bool
        }

        private struct SustainedDepth {
            var count = 0
            var first: Double?
            var last: Double?
            var oppositeSeen = false
            var supportCount = 0
            var lastSupport: Double?
            var strong = false

            mutating func update(_ leg: Leg, opposite: Leg, at time: Double) -> Reason? {
                if let last, time - last > Limits.continuity { self = Self() }
                guard leg.observation != nil else { return nil }
                guard leg.strict else {
                    self = Self()
                    return nil
                }
                if first == nil { first = time }
                last = time
                count = min(thresholds.requiredStableFrames, count + 1)
                strong = strong || (leg.drop ?? 0) >= Limits.strongDrop
                if let other = opposite.observation {
                    oppositeSeen = true
                    if let drop = opposite.drop, drop >= Limits.minimumDrop,
                       other.kneeAngle <= bentAngle, other.normalizedThighHeight <= sqrt(0.5) {
                        if let lastSupport, time - lastSupport > Limits.continuity { supportCount = 0 }
                        supportCount = min(2, supportCount + 1)
                        lastSupport = time
                    }
                }
                guard count == thresholds.requiredStableFrames, strong,
                      (leg.ema ?? 180) <= thresholds.loweredThreshold,
                      let first, time - first >= minimumDwell else { return nil }
                if !oppositeSeen { return .unilateralDepth }
                guard supportCount == 2, let lastSupport, time - lastSupport <= Limits.continuity else { return nil }
                return .sustainedDepth
            }
        }

        private var leftRun = SustainedDepth()
        private var rightRun = SustainedDepth()
        private static let maximumSamples = 9
        private var samples: [Sample] = []

        mutating func observe(_ left: Leg, _ right: Leg, at time: Double) -> Reason? {
            let sustainedLeft = leftRun.update(left, opposite: right, at: time)
            let sustainedRight = rightRun.update(right, opposite: left, at: time)
            if let sustained = sustainedLeft ?? sustainedRight { return sustained }
            samples.removeAll { time - $0.time > Limits.continuity }
            guard left.supportsDepth || right.supportsDepth else { return nil }
            let sample = Sample(time: time, leftStrict: left.strict, rightStrict: right.strict,
                                leftSupport: left.supportsDepth, rightSupport: right.supportsDepth)
            let corroborated = samples.contains { earlier in
                time - earlier.time >= minimumDwell &&
                    ((earlier.leftStrict && sample.rightSupport) || (earlier.rightStrict && sample.leftSupport)
                     || (sample.leftStrict && earlier.rightSupport) || (sample.rightStrict && earlier.leftSupport))
            }
            if samples.count == Self.maximumSamples { samples.removeFirst() }
            samples.append(sample)
            return corroborated ? .bilateralDepth : nil
        }
    }

    private(set) var phase = Phase.seekingStanding
    private var left = Leg()
    private var right = Leg()
    private var bottom = Bottom()
    private var timestamp: Double?
    private var lastObserved: Double?
    private var departure: Double?
    private var uprightSince: Double?
    private var aspectRatio: Double?
    private var rotationAngle: Double?

    static func replay(_ session: PoseReplaySession, onStep: ((Double, Step) -> Void)? = nil) throws -> [Double] {
        try PoseReplayRunner.validateHeader(session)
        var previousTime = 0.0
        var cycle = Self()
        var times: [Double] = []
        for event in session.events {
            try PoseReplayRunner.validateEvent(event, after: previousTime)
            previousTime = event.seconds
            let step = cycle.process(event)
            onStep?(event.seconds, step)
            if step.counted { times.append(event.seconds) }
        }
        return times
    }

    mutating func process(_ event: PoseReplayEvent) -> Step {
        let time = event.seconds
        if event.kind == .reset {
            self = Self()
            return result(.reset)
        }
        guard time.isFinite, time >= 0 else { return discard(.interrupted) }
        if let timestamp {
            if time == timestamp { return result(.repeatedTimestamp) }
            if time < timestamp { return discard(.interrupted) }
            if time - timestamp > Limits.continuity {
                self.timestamp = time
                return discard(.interrupted)
            }
        }
        timestamp = time
        if let pose = event.pose {
            if let aspectRatio, let rotationAngle,
               pose.aspectRatio != aspectRatio || pose.rotationAngle != rotationAngle {
                return discard(.changedGeometry)
            }
            aspectRatio = pose.aspectRatio
            rotationAngle = pose.rotationAngle
        }
        left.update(PoseReplayDepthAudit.observe(event.pose, side: .left), at: time)
        right.update(PoseReplayDepthAudit.observe(event.pose, side: .right), at: time)
        if let lastObserved, time - lastObserved > Limits.continuity {
            return discard(.interrupted)
        }
        if let pose = event.pose, departure != nil && supportMoved(in: pose) { return discard(.movingSupport) }
        let observed = departure == nil
            ? (left.observation != nil || right.observation != nil)
            : (left.drop != nil || right.drop != nil)
        guard let pose = event.pose, observed else {
            uprightSince = nil
            return result(.missingJoints)
        }
        lastObserved = time
        if let departure, time - departure > Limits.maxCycle { return discard(.expired) }
        if departure == nil {
            if time - (left.calibratedAt ?? time) > Limits.maxCycle { left.reference = nil }
            if time - (right.calibratedAt ?? time) > Limits.maxCycle { right.reference = nil }
        }
        let looksUpright = (left.upright || right.upright) && left.compatibleWithStance && right.compatibleWithStance
        if looksUpright {
            bottom = Bottom()
            if uprightSince == nil { uprightSince = time }
            if departure == nil {
                left.calibrate(at: time)
                right.calibrate(at: time)
            }
            let confirmed = time - (uprightSince ?? time) >= Self.minimumDwell
                && ((left.reference != nil && left.upright) || (right.reference != nil && right.upright))
            if confirmed {
                let counted = phase == .lowered || phase == .returning
                let missed = phase == .descending
                phase = .standing
                departure = nil
                bottom = Bottom()
                left.calibrate(at: time)
                right.calibrate(at: time)
                return result(counted ? .counted : (missed ? .insufficientDepth : .standing))
            }
            if phase == .lowered { phase = .returning }
            return result(phase == .returning ? .returning : .seekingStance)
        }

        let unconfirmedReturn = uprightSince != nil && departure != nil
        uprightSince = nil
        left.standingSince = nil
        right.standingSince = nil
        guard left.drop != nil || right.drop != nil else { return result(.seekingStance) }
        let deepest = max(left.drop ?? 0, right.drop ?? 0)
        if unconfirmedReturn && (phase == .descending || deepest >= Limits.minimumDrop) { return discard(.renewedDescent) }
        switch phase {
        case .seekingStanding, .insufficientData:
            return result(.seekingStance)
        case .standing:
            guard deepest >= 1 - Limits.standingHeight else { return result(.standing) }
            guard !supportMoved(in: pose) else { return discard(.movingSupport) }
            departure = time
            phase = .descending
        case .returning:
            if deepest >= Limits.minimumDrop { return discard(.renewedDescent) }
            return result(.returning)
        case .lowered, .descending:
            break
        }

        if (left.strict && right.upright) || (right.strict && left.upright) { return discard(.conflictingLegs) }
        if let l = left.drop, let r = right.drop, deepest >= Limits.minimumDrop,
           abs(l - r) > Limits.supportTolerance { return discard(.conflictingLegs) }
        if phase == .lowered {
            if deepest < Limits.minimumDrop { phase = .returning }
            return result(phase == .returning ? .returning : .holdingDepth)
        }
        if deepest < Limits.minimumDrop { bottom = Bottom() }
        if let reason = bottom.observe(left, right, at: time) {
            phase = .lowered
            return result(reason)
        }
        return result(departure == time ? .descent : .awaitingDepth)
    }

    private func supportMoved(in pose: PoseReplayPose) -> Bool {
        if left.footMoved(pose.points.first { $0.joint == .leftAnkle }, aspect: pose.aspectRatio)
            || right.footMoved(pose.points.first { $0.joint == .rightAnkle }, aspect: pose.aspectRatio) { return true }
        guard let l = left.observation, let r = right.observation,
              let ls = left.reference, let rs = right.reference else { return false }
        return abs((l.hipX - r.hipX) - (ls.hipX - rs.hipX))
            > Limits.supportTolerance * min(ls.hipAnkleHeight, rs.hipAnkleHeight)
    }

    private func result(_ reason: Reason) -> Step {
        Step(phase: phase, reason: reason, counted: reason == .counted)
    }

    private mutating func discard(_ reason: Reason) -> Step {
        let watermark = timestamp
        self = Self()
        timestamp = watermark
        phase = .insufficientData
        return result(reason)
    }
}
#endif
