#if DEBUG
import Foundation

/// Supplemental causal detector. All state belongs to one replay and one calibrated excursion.
struct BilateralCycleEvidence {
    typealias Observation = PoseReplayDepthAudit.KneeObservation
    private typealias Recovery = PoseReplayOcclusionRecovery
    private typealias Stance = Recovery.Stance
    private static let thresholds = SquatCounter()

    struct Witness {
        let geometry: Observation
        let ema: Double
        let drop: Double

        var supportsSmoothedDepth: Bool {
            ema <= thresholds.loweredThreshold && drop >= Recovery.strongDrop
        }
    }

    struct DepthFrame {
        let seconds: TimeInterval
        let left: Witness?
        let right: Witness?

        var smoothedDepth: Bool {
            left?.supportsSmoothedDepth == true || right?.supportsSmoothedDepth == true
        }
    }

    struct Confirmation {
        let countedAt: TimeInterval
        let frames: [DepthFrame]
    }

    private struct LegHistory {
        var lastReliable: TimeInterval?
        var ema: Double?

        mutating func update(_ observation: Observation?, at time: TimeInterval) {
            guard let observation else {
                ema = nil
                return
            }
            ema = ema.map { 0.35 * observation.kneeAngle + 0.65 * $0 } ?? observation.kneeAngle
            lastReliable = time
        }

        func witness(_ leg: Observation?, relativeHeight: Double?) -> Witness? {
            guard let leg, let relativeHeight, relativeHeight > 0, let ema,
                  Recovery.passesDepth(leg), 1 - relativeHeight >= Recovery.minimumDrop else { return nil }
            return Witness(geometry: leg, ema: ema, drop: 1 - relativeHeight)
        }
    }

    private enum Phase { case standing, descending, lowered, returning }
    private var stance: Stance?
    private var phase = Phase.standing
    private var left = LegHistory()
    private var right = LegHistory()
    private var frames: [DepthFrame] = []

    mutating func observe(_ pose: PoseReplayPose, left l: Observation?, right r: Observation?,
                          sample: PoseReplayDepthSample,
                          boundary: PoseReplayOcclusionRecovery.Boundary) -> Confirmation? {
        let time = sample.seconds
        // Inherited counts consume the entire excursion, including an early single-leg return.
        if sample.counted || boundary == .recovered || sample.invalidGeometry {
            self = Self()
        }
        if let stance {
            guard time - stance.time <= Recovery.maxCycle,
                  let lastLeft = left.lastReliable, let lastRight = right.lastReliable,
                  time - min(lastLeft, lastRight) <= Recovery.maxOcclusion,
                  time - max(lastLeft, lastRight) <= Recovery.continuity,
                  ((l != nil && r != nil) || Self.supportIsVisible(pose)),
                  stance.feetAndHipsStable(pose, left: l, right: r) else {
                self = Self()
                return nil
            }
        }
        left.update(l, at: time)
        right.update(r, at: time)
        let leftHeight = stance.flatMap { reference in l.map { $0.hipAnkleHeight / reference.left.hipAnkleHeight } }
        let rightHeight = stance.flatMap { reference in r.map { $0.hipAnkleHeight / reference.right.hipAnkleHeight } }
        // Contradictory pelvis travel also invalidates the return (for example, a planted lunge).
        if let leftHeight, let rightHeight, abs(leftHeight - rightHeight) > Recovery.supportTolerance {
            self = Self()
            return nil
        }
        if boundary != .tracking, let l, let r,
           let leftEMA = left.ema, let rightEMA = right.ema,
           min(leftEMA, rightEMA) >= Self.thresholds.standingThreshold,
           min(leftHeight ?? 1, rightHeight ?? 1) >= Recovery.standingHeight {
            let confirmation = (phase == .lowered || phase == .returning)
                ? Confirmation(countedAt: time, frames: frames) : nil
            stance = Stance(left: l, right: r, time: time)
            phase = .standing
            frames.removeAll()
            return confirmation
        }
        guard stance != nil else { return nil }
        let bothBelowReturn = max(leftHeight ?? 1, rightHeight ?? 1) < Recovery.standingHeight
        switch phase {
        case .standing:
            guard bothBelowReturn, let l, let r,
                  max(l.kneeAngle, r.kneeAngle) < Self.thresholds.standingThreshold else { return nil }
            // Observe the descent before accepting bottom evidence. A jump from stance to a
            // unilateral low sample cannot establish a bilateral excursion.
            guard !Recovery.passesDepth(l), !Recovery.passesDepth(r) else {
                self = Self()
                return nil
            }
            phase = .descending
            return nil
        case .returning:
            // A new descent before a confirmed return cannot complete the previous repetition.
            if bothBelowReturn { self = Self() }
            return nil
        case .descending, .lowered:
            if max(leftHeight ?? 0, rightHeight ?? 0) >= Recovery.standingHeight {
                if phase == .lowered { phase = .returning } else { self = Self() }
                return nil
            }
        }
        guard phase == .descending else { return nil }
        // A visible bilateral rebound out of the supporting depth band splits bottom episodes.
        if let leftHeight, let rightHeight, 1 - min(leftHeight, rightHeight) < Recovery.minimumDrop {
            frames.removeAll()
        }
        let leftDepth = left.witness(l, relativeHeight: leftHeight)
        let rightDepth = right.witness(r, relativeHeight: rightHeight)
        guard leftDepth != nil || rightDepth != nil else { return nil }
        if let last = frames.last, time - last.seconds > Recovery.continuity { frames.removeAll() }
        if frames.count == Self.thresholds.requiredStableFrames { frames.removeFirst() }
        frames.append(DepthFrame(seconds: time, left: leftDepth, right: rightDepth))
        if frames.count == Self.thresholds.requiredStableFrames,
           frames.contains(where: { $0.left != nil }),
           frames.contains(where: { $0.right != nil }),
           frames.contains(where: { $0.smoothedDepth }) {
            phase = .lowered
        }
        return nil
    }

    private static func supportIsVisible(_ pose: PoseReplayPose) -> Bool {
        func reliable(_ joint: PoseReplayJoint) -> Bool {
            pose.points.contains { $0.joint == joint && $0.confidence >= 0.5 }
        }
        return reliable(.leftAnkle) && reliable(.rightAnkle) && (reliable(.leftKnee) || reliable(.rightKnee))
    }
}
#endif
