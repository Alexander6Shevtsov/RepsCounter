#if DEBUG
import Foundation

struct PoseReplaySquatCycle {
    enum Phase: String {
        case seekingStanding, standing, descending, lowered, returning, insufficientData
    }

    enum Reason: String {
        case seekingStance, standing, descent, awaitingDepth, bilateralDepth, unilateralDepth
        case sustainedDepth, corroboratedHipDepth, holdingDepth, missingJoints, insufficientDepth, conflictingLegs, movingSupport, changedGeometry
        case interrupted, expired, repeatedTimestamp, reset, renewedDescent, returning, counted
        case awaitingSupport, supportExpired, reacquiredDuringAscent, toleratedAscentRegression
    }

    struct Step: Equatable {
        let phase: Phase
        let reason: Reason
        let counted: Bool
        var projectionConflictAccepted = false
    }

    private typealias Observation = PoseReplayDepthAudit.KneeObservation
    private typealias Limits = PoseReplayOcclusionRecovery
    private static let thresholds = SquatCounter()
    private static let bentAngle = (thresholds.standingThreshold + thresholds.loweredThreshold) / 2
    private static let minimumDwell = Limits.continuity / 4

    private enum FootSupport {
        case unknown, stable, displaced, unverifiedDisplacement
    }

    private enum SupportRecovery: Equatable {
        case none, waiting(BodyLeg, since: Double), restored
    }

    private struct SupportOffset {
        let horizontal: Double
        let vertical: Double

        var magnitude: Double { hypot(horizontal, vertical) }
    }

    private struct RelativeSupportEvidence {
        private static let minimumShift = 0.15
        private static let stationaryTolerance = 0.05
        private static let minimumAlignment = 0.8

        private struct Sample {
            let side: BodyLeg
            let offset: SupportOffset
            let time: Double
        }

        private var previous: Sample?

        mutating func confirms(left: SupportOffset?, right: SupportOffset?, at time: Double) -> Bool {
            guard let left, let right else {
                previous = nil
                return false
            }
            let side: BodyLeg
            let moving: SupportOffset
            let stable: SupportOffset
            if left.magnitude >= Self.minimumShift && right.magnitude <= Self.stationaryTolerance {
                side = .left
                moving = left
                stable = right
            } else if right.magnitude >= Self.minimumShift && left.magnitude <= Self.stationaryTolerance {
                side = .right
                moving = right
                stable = left
            } else {
                previous = nil
                return false
            }
            let offset = SupportOffset(horizontal: moving.horizontal - stable.horizontal,
                                       vertical: moving.vertical - stable.vertical)
            guard offset.magnitude >= Self.minimumShift else {
                previous = nil
                return false
            }
            let current = Sample(side: side, offset: offset, time: time)
            guard let previous, previous.side == side, time > previous.time,
                  time - previous.time <= Limits.continuity else {
                self.previous = current
                return false
            }
            let alignment = (offset.horizontal * previous.offset.horizontal + offset.vertical * previous.offset.vertical)
                / (offset.magnitude * previous.offset.magnitude)
            guard alignment >= Self.minimumAlignment else {
                self.previous = current
                return false
            }
            return time - previous.time >= minimumDwell
        }
    }

    private struct Leg {
        var observation: Observation?
        var ema: Double?
        var lastSeen: Double?
        var reference: Observation?
        var heldReference: Observation?
        var supportReference: Observation?
        var cycleReference: Observation? { heldReference ?? reference }
        var calibratedAt: Double?
        var standingSince: Double?

        mutating func freezeSupport(at time: Double) {
            guard let lastSeen, time - lastSeen <= Limits.maxOcclusion else {
                supportReference = nil
                return
            }
            supportReference = reference
        }

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
            guard let observation, let cycleReference else { return nil }
            return 1 - observation.hipAnkleHeight / cycleReference.hipAnkleHeight
        }

        var upright: Bool {
            (observation?.kneeAngle ?? 0) >= thresholds.standingThreshold
        }

        func isRising(from previous: Observation?) -> Bool {
            guard let previous, let observation else { return false }
            return observation.hipAnkleHeight > previous.hipAnkleHeight && observation.kneeAngle > previous.kneeAngle
        }

        func continuesReturn(from previous: Observation?) -> Bool {
            if isRising(from: previous) { return true }
            guard let previous, let cycleReference, upright, compatibleWithStance else { return false }
            return previous.kneeAngle >= thresholds.standingThreshold &&
                previous.hipAnkleHeight >= Limits.standingHeight * cycleReference.hipAnkleHeight
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

        var frozenSupportOffset: SupportOffset? {
            guard let observation, let supportReference, supportReference.hipAnkleHeight > 0 else { return nil }
            return SupportOffset(
                horizontal: Double(observation.ankle.x - supportReference.ankle.x) / supportReference.hipAnkleHeight,
                vertical: Double(observation.ankle.y - supportReference.ankle.y) / supportReference.hipAnkleHeight
            )
        }

        func support(in pose: PoseReplayPose?, ankle: PoseReplayJoint) -> FootSupport {
            guard let reference = supportReference ?? cycleReference else { return .unknown }
            let limit = Limits.supportTolerance * reference.hipAnkleHeight
            if let observation {
                let distance = hypot(observation.ankle.x - reference.ankle.x, observation.ankle.y - reference.ankle.y)
                return distance > limit ? .displaced : .stable
            }
            guard let pose, let point = pose.points.first(where: { $0.joint == ankle }),
                  (0.5...1).contains(point.confidence) else { return .unknown }
            let distance = hypot(point.horizontalPosition * pose.aspectRatio - reference.ankle.x,
                                 point.verticalPosition - reference.ankle.y)
            return distance > limit ? .unverifiedDisplacement : .unknown
        }
    }

    private struct ProjectionConflictEvidence {
        private struct Sample {
            let time: Double
            let left: Observation
            let right: Observation
            let leftLength: Double
            let rightLength: Double
        }

        private var previous: Sample?

        mutating func agrees(_ pose: PoseReplayPose?, left: Leg, right: Leg, at time: Double) -> Bool {
            guard let pose, let l = left.observation, let r = right.observation,
                  let ls = left.cycleReference, let rs = right.cycleReference,
                  let ll = Self.length(pose, side: .left), let rl = Self.length(pose, side: .right) else {
                if let previous, time - previous.time > Limits.maxOcclusion { self.previous = nil }
                return false
            }
            let current = Sample(time: time, left: l, right: r, leftLength: ll, rightLength: rl)
            let earlier = previous
            previous = current
            guard let earlier, time - earlier.time >= minimumDwell,
                  time - earlier.time <= Limits.maxOcclusion else { return false }
            let scale = min(ls.hipAnkleHeight, rs.hipAnkleHeight)
            guard scale > 0,
                  abs(Self.hip(ls) - Self.hip(rs)) <= 0.12 * scale,
                  abs(Self.hip(l) - Self.hip(r)) <= 0.12 * scale,
                  abs((Self.hip(ls) - Self.hip(l)) - (Self.hip(rs) - Self.hip(r)))
                    <= Limits.supportTolerance * scale,
                  (0.65...1.35).contains(ll / earlier.leftLength),
                  (0.65...1.35).contains(rl / earlier.rightLength) else { return false }
            let leftTravel = Self.hip(l) - Self.hip(earlier.left)
            let rightTravel = Self.hip(r) - Self.hip(earlier.right)
            let leftBend = l.kneeAngle - earlier.left.kneeAngle
            let rightBend = r.kneeAngle - earlier.right.kneeAngle
            let pelvicTravel = (leftTravel + rightTravel) / 2
            return (pelvicTravel < 0 && leftBend < 0 && rightBend < 0)
                || (pelvicTravel > 0 && leftBend > 0 && rightBend > 0)
                || (leftTravel == 0 && rightTravel == 0 && leftBend == 0 && rightBend == 0)
        }

        private static func hip(_ value: Observation) -> Double {
            Double(value.ankle.y) + value.hipAnkleHeight
        }

        private static func length(_ pose: PoseReplayPose, side: BodyLeg) -> Double? {
            let joints: [PoseReplayJoint] = side == .left
                ? [.leftHip, .leftKnee, .leftAnkle] : [.rightHip, .rightKnee, .rightAnkle]
            let points = joints.compactMap { joint in pose.points.first { $0.joint == joint } }
            guard points.count == 3 else { return nil }
            let thigh = hypot((points[0].horizontalPosition - points[1].horizontalPosition) * pose.aspectRatio,
                              points[0].verticalPosition - points[1].verticalPosition)
            let shin = hypot((points[2].horizontalPosition - points[1].horizontalPosition) * pose.aspectRatio,
                             points[2].verticalPosition - points[1].verticalPosition)
            let length = thigh + shin
            return length.isFinite && length > 0 ? length : nil
        }
    }

    private struct WeakHipDepthEvidence {
        private struct Sample {
            let side: BodyLeg
            let time: Double
        }

        private var previous: Sample?

        mutating func observe(_ pose: PoseReplayPose, left: Leg, right: Leg, at time: Double) -> Bool {
            let side: BodyLeg
            if Self.qualifies(pose, side: .left, leg: left, opposite: right) {
                side = .left
            } else if Self.qualifies(pose, side: .right, leg: right, opposite: left) {
                side = .right
            } else {
                previous = nil
                return false
            }
            let earlier = previous
            previous = Sample(side: side, time: time)
            guard let earlier, earlier.side == side else { return false }
            let interval = time - earlier.time
            return interval >= minimumDwell && interval <= Limits.continuity
        }

        private static func qualifies(_ pose: PoseReplayPose, side: BodyLeg, leg: Leg, opposite: Leg) -> Bool {
            guard leg.observation == nil, let reference = leg.cycleReference,
                  let other = opposite.observation, let otherReference = opposite.cycleReference,
                  let otherDrop = opposite.drop, otherDrop >= Limits.minimumDrop,
                  other.kneeAngle <= bentAngle,
                  reference.hipAnkleHeight > 0, otherReference.hipAnkleHeight > 0 else { return false }
            let hipJoint: PoseReplayJoint = side == .left ? .leftHip : .rightHip
            let kneeJoint: PoseReplayJoint = side == .left ? .leftKnee : .rightKnee
            let ankleJoint: PoseReplayJoint = side == .left ? .leftAnkle : .rightAnkle
            guard let hip = pose.points.first(where: { $0.joint == hipJoint }),
                  let knee = pose.points.first(where: { $0.joint == kneeJoint }),
                  let ankle = pose.points.first(where: { $0.joint == ankleJoint }),
                  hip.confidence >= 0.30, hip.confidence < 0.50,
                  (0.65...1).contains(knee.confidence), (0.65...1).contains(ankle.confidence),
                  [hip, knee, ankle].allSatisfy({ $0.horizontalPosition.isFinite && $0.verticalPosition.isFinite }) else { return false }
            let height = reference.hipAnkleHeight
            let thighX = (hip.horizontalPosition - knee.horizontalPosition) * pose.aspectRatio
            let thighY = hip.verticalPosition - knee.verticalPosition
            let shinX = (ankle.horizontalPosition - knee.horizontalPosition) * pose.aspectRatio
            let shinY = ankle.verticalPosition - knee.verticalPosition
            let thighLength = hypot(thighX, thighY)
            let shinLength = hypot(shinX, shinY)
            guard thighY < 0, thighLength > 0, shinLength > 0,
                  (0.65...1.35).contains((thighLength + shinLength) / height),
                  1 - (hip.verticalPosition - ankle.verticalPosition) / height >= Limits.minimumDrop else { return false }
            let cosine = (thighX * shinX + thighY * shinY) / (thighLength * shinLength)
            let angle = acos(max(-1, min(1, cosine))) * 180 / .pi
            guard angle <= thresholds.loweredThreshold else { return false }
            let otherHipHeight = Double(other.ankle.y) + other.hipAnkleHeight
            return abs(hip.verticalPosition - otherHipHeight) <= 0.12 * min(height, otherReference.hipAnkleHeight)
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
        var weakHip = WeakHipDepthEvidence()

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
    private var supportRecovery = SupportRecovery.none
    private var relativeSupport = RelativeSupportEvidence()
    private var revalidatingAscent = false
    private var projectionConflict = ProjectionConflictEvidence()
    private var projectionConflictAccepted = false
    private var ascentToleranceUsed = false
    private var timestamp: Double?
    private var lastObserved: Double?
    private var departure: Double?
    private var uprightSince: Double?
    private var aspectRatio: Double?
    private var rotationAngle: Double?

    static func replay(_ session: PoseReplaySession, onStep: ((Double, Step) -> Void)? = nil) throws -> [Double] {
        try replay(session, ignoringSupportChecks: false, corroboratedDepth: false, onStep: onStep)
    }

    static func replayIgnoringSupportChecks(_ session: PoseReplaySession,
                                            onStep: ((Double, Step) -> Void)? = nil) throws -> [Double] {
        try replay(session, ignoringSupportChecks: true, corroboratedDepth: false, onStep: onStep)
    }

    static func replayWithCorroboratedHipDepth(_ session: PoseReplaySession,
                                               onStep: ((Double, Step) -> Void)? = nil) throws -> [Double] {
        try replay(session, ignoringSupportChecks: false, corroboratedDepth: true, onStep: onStep)
    }

    static func replayWithAscentTolerance(_ session: PoseReplaySession,
                                          onStep: ((Double, Step) -> Void)? = nil) throws -> [Double] {
        try replay(session, ignoringSupportChecks: false, corroboratedDepth: true,
                   toleratingAscentRegression: true, onStep: onStep)
    }

    static func replayWithProjectionConflictEvidence(_ session: PoseReplaySession,
                                                      onStep: ((Double, Step) -> Void)? = nil) throws -> [Double] {
        try replay(session, ignoringSupportChecks: false, corroboratedDepth: true,
                   toleratingAscentRegression: true, usingProjectionConflictEvidence: true, onStep: onStep)
    }

    private static func replay(_ session: PoseReplaySession, ignoringSupportChecks: Bool,
                               corroboratedDepth: Bool, toleratingAscentRegression: Bool = false,
                               usingProjectionConflictEvidence: Bool = false,
                               onStep: ((Double, Step) -> Void)?) throws -> [Double] {
        try PoseReplayRunner.validateHeader(session)
        var previousTime = 0.0
        var cycle = Self()
        var times: [Double] = []
        for event in session.events {
            try PoseReplayRunner.validateEvent(event, after: previousTime)
            previousTime = event.seconds
            let step = cycle.process(event, ignoringSupportChecks: ignoringSupportChecks, corroboratedDepth: corroboratedDepth,
                                     toleratingAscentRegression: toleratingAscentRegression,
                                     usingProjectionConflictEvidence: usingProjectionConflictEvidence)
            onStep?(event.seconds, step)
            if step.counted { times.append(event.seconds) }
        }
        return times
    }

    mutating func process(_ event: PoseReplayEvent) -> Step {
        process(event, ignoringSupportChecks: false, corroboratedDepth: false)
    }

    private mutating func process(_ event: PoseReplayEvent, ignoringSupportChecks: Bool, corroboratedDepth: Bool,
                                  toleratingAscentRegression: Bool = false,
                                  usingProjectionConflictEvidence: Bool = false) -> Step {
        let time = event.seconds
        projectionConflictAccepted = false
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
        let previousLeft = left.observation
        let previousRight = right.observation
        left.update(PoseReplayDepthAudit.observe(event.pose, side: .left), at: time)
        right.update(PoseReplayDepthAudit.observe(event.pose, side: .right), at: time)
        let projectionAgrees = usingProjectionConflictEvidence
            && projectionConflict.agrees(event.pose, left: left, right: right, at: time)
        if let lastObserved, time - lastObserved > Limits.continuity {
            return discard(.interrupted)
        }
        if !ignoringSupportChecks, departure != nil, let step = checkSupport(in: event.pose, at: time) {
            if revalidatingAscent && step.reason == .awaitingSupport { return discard(.interrupted) }
            return step
        }
        if revalidatingAscent {
            guard let l = left.drop, let r = right.drop else { return discard(.interrupted) }
            if max(l, r) >= Limits.minimumDrop && abs(l - r) > Limits.supportTolerance {
                guard projectionAgrees else { return discard(.conflictingLegs) }
                projectionConflictAccepted = true
            }
        }
        let observed = departure == nil
            ? (left.observation != nil || right.observation != nil)
            : (left.drop != nil || right.drop != nil)
        guard let pose = event.pose, observed else {
            bottom.weakHip = WeakHipDepthEvidence()
            uprightSince = nil
            return result(.missingJoints)
        }
        lastObserved = time
        if let departure, time - departure > Limits.maxCycle { return discard(.expired) }
        if departure == nil {
            if time - (left.calibratedAt ?? time) > Limits.maxCycle { left.reference = nil }
            if time - (right.calibratedAt ?? time) > Limits.maxCycle { right.reference = nil }
        }
        let needsBothLegs = revalidatingAscent || supportRecovery == .restored
        let upright = needsBothLegs ? left.upright && right.upright : left.upright || right.upright
        let looksUpright = upright && left.compatibleWithStance && right.compatibleWithStance
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
                left.heldReference = nil
                right.heldReference = nil
                left.supportReference = nil
                right.supportReference = nil
                supportRecovery = .none
                relativeSupport = RelativeSupportEvidence()
                revalidatingAscent = false
                ascentToleranceUsed = false
                projectionConflict = ProjectionConflictEvidence()
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
        if unconfirmedReturn && phase == .descending { return discard(.renewedDescent) }
        switch phase {
        case .seekingStanding, .insufficientData:
            return result(.seekingStance)
        case .standing:
            guard deepest >= 1 - Limits.standingHeight else { return result(.standing) }
            if !ignoringSupportChecks, let step = checkSupport(in: pose, at: time) { return step }
            left.freezeSupport(at: time)
            right.freezeSupport(at: time)
            departure = time
            phase = .descending
        case .returning:
            return continueReturn(previousLeft: previousLeft, previousRight: previousRight,
                                  unconfirmedReturn: unconfirmedReturn,
                                  toleratingAscentRegression: toleratingAscentRegression)
        case .lowered, .descending:
            break
        }

        if (left.strict && right.upright) || (right.strict && left.upright) { return discard(.conflictingLegs) }
        if let l = left.drop, let r = right.drop, deepest >= Limits.minimumDrop,
           abs(l - r) > Limits.supportTolerance {
            guard projectionAgrees else { return discard(.conflictingLegs) }
            projectionConflictAccepted = true
        }
        if phase == .lowered {
            if deepest < Limits.minimumDrop { phase = .returning }
            return result(phase == .returning ? .returning : .holdingDepth)
        }
        if deepest < Limits.minimumDrop { bottom = Bottom() }
        if let reason = bottom.observe(left, right, at: time) {
            phase = .lowered
            return result(reason)
        }
        if corroboratedDepth, bottom.weakHip.observe(pose, left: left, right: right, at: time) {
            phase = .lowered
            return result(.corroboratedHipDepth)
        }
        return result(departure == time ? .descent : .awaitingDepth)
    }

    private mutating func continueReturn(previousLeft: Observation?, previousRight: Observation?,
                                         unconfirmedReturn: Bool, toleratingAscentRegression: Bool) -> Step {
        let leftDeep = (left.drop ?? 0) >= Limits.minimumDrop
        let rightDeep = (right.drop ?? 0) >= Limits.minimumDrop
        if revalidatingAscent {
            guard !unconfirmedReturn else { return discard(.interrupted) }
            if left.continuesReturn(from: previousLeft) && right.continuesReturn(from: previousRight) {
                return result(.returning)
            }
            if toleratingAscentRegression, !ascentToleranceUsed,
               Self.hipAndHeightRise(left, from: previousLeft),
               Self.hipAndHeightRise(right, from: previousRight),
               (Self.smallKneeRegression(left, from: previousLeft) && right.isRising(from: previousRight)
                || Self.smallKneeRegression(right, from: previousRight) && left.isRising(from: previousLeft)) {
                ascentToleranceUsed = true
                return result(.toleratedAscentRegression)
            }
            return discard(.interrupted)
        }
        guard leftDeep || rightDeep else { return result(.returning) }
        if (leftDeep && previousLeft != nil) || (rightDeep && previousRight != nil) {
            return discard(.renewedDescent)
        }
        guard !unconfirmedReturn, supportRecovery == .none,
              let l = left.drop, let r = right.drop, abs(l - r) <= Limits.supportTolerance,
              !left.upright, !right.upright else { return discard(.interrupted) }
        let witnessIsRising = leftDeep ? right.isRising(from: previousRight) : left.isRising(from: previousLeft)
        guard witnessIsRising else { return discard(.interrupted) }
        revalidatingAscent = true
        return result(.reacquiredDuringAscent)
    }

    private static func hipAndHeightRise(_ leg: Leg, from previous: Observation?) -> Bool {
        guard let previous, let current = leg.observation else { return false }
        let previousHip = Double(previous.ankle.y) + previous.hipAnkleHeight
        let currentHip = Double(current.ankle.y) + current.hipAnkleHeight
        return currentHip > previousHip && current.hipAnkleHeight > previous.hipAnkleHeight
    }

    private static func smallKneeRegression(_ leg: Leg, from previous: Observation?) -> Bool {
        guard let previous, let current = leg.observation else { return false }
        let regression = previous.kneeAngle - current.kneeAngle
        return regression > 0 && regression <= 5
    }

    private mutating func checkSupport(in pose: PoseReplayPose?, at time: Double) -> Step? {
        let l = left.support(in: pose, ankle: .leftAnkle)
        let r = right.support(in: pose, ankle: .rightAnkle)
        if l == .displaced || r == .displaced || hipSpanChanged { return discard(.movingSupport) }
        if departure != nil, (phase == .lowered || phase == .returning),
           relativeSupport.confirms(left: left.frozenSupportOffset, right: right.frozenSupportOffset, at: time) {
            return discard(.movingSupport)
        }

        let suspect: BodyLeg
        switch supportRecovery {
        case .none:
            guard l == .unverifiedDisplacement || r == .unverifiedDisplacement else { return nil }
            guard phase == .lowered || phase == .returning else { return discard(.movingSupport) }
            guard uprightSince == nil else { return discard(.interrupted) }
            suspect = l == .unverifiedDisplacement ? .left : .right
            if suspect == .left { left.heldReference = left.reference }
            else { right.heldReference = right.reference }
            supportRecovery = .waiting(suspect, since: time)
        case let .waiting(side, since):
            guard time - since <= Limits.continuity else { return discard(.supportExpired) }
            if l == .stable && r == .stable {
                supportRecovery = .restored
                return nil
            }
            suspect = side
        case .restored:
            return l == .stable && r == .stable ? nil : discard(.interrupted)
        }

        let witness = suspect == .left ? right : left
        guard (suspect == .left ? r : l) == .stable else { return discard(.interrupted) }
        if let departure, time - departure > Limits.maxCycle { return discard(.expired) }
        guard !witness.upright, let drop = witness.drop else { return discard(.interrupted) }
        if drop < Limits.minimumDrop { phase = .returning }
        if phase == .returning && drop >= Limits.minimumDrop { return discard(.renewedDescent) }
        uprightSince = nil
        lastObserved = time
        return result(.awaitingSupport)
    }

    private var hipSpanChanged: Bool {
        guard let l = left.observation, let r = right.observation,
              let ls = left.cycleReference, let rs = right.cycleReference else { return false }
        return abs((l.hipX - r.hipX) - (ls.hipX - rs.hipX))
            > Limits.supportTolerance * min(ls.hipAnkleHeight, rs.hipAnkleHeight)
    }

    private func result(_ reason: Reason) -> Step {
        Step(phase: phase, reason: reason, counted: reason == .counted,
             projectionConflictAccepted: projectionConflictAccepted)
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
