#if DEBUG
import Foundation

struct PoseReplayRecoveryResult {
    let baseline: PoseReplayResult
    let countedAtSeconds: [TimeInterval]
    let supplementalAtSeconds: [TimeInterval]
}

enum PoseReplayOcclusionRecovery {
    private typealias Observation = PoseReplayDepthAudit.KneeObservation
    private static let thresholds = SquatCounter()
    private static let maximumThighHeight = 0.35
    private static let requiredFrames = thresholds.requiredStableFrames

    static func replay(_ session: PoseReplaySession) throws -> PoseReplayRecoveryResult {
        let baseline = try PoseReplayRunner.replay(session)
        var samples = baseline.depthSamples.makeIterator()
        var cycle = Cycle()
        var previous: PoseReplayEvent?
        var supplemental: [TimeInterval] = []
        var counts: [TimeInterval] = []

        // Baseline emits exactly one sample per pose, including missing poses, and none for resets.
        for event in session.events {
            if event.kind == .reset {
                cycle = Cycle()
                previous = nil
                continue
            }
            guard let sample = samples.next() else { throw PoseReplayError.invalidTimeline }
            if let previous {
                let interval = event.seconds - previous.seconds
                if interval <= 0 || interval > 0.25
                    || previous.pose?.aspectRatio != event.pose?.aspectRatio
                    || previous.pose?.rotationAngle != event.pose?.rotationAngle { cycle = Cycle() }
            }
            previous = event
            if sample.counted { counts.append(event.seconds) }
            guard let pose = event.pose else {
                cycle = Cycle()
                continue
            }
            if cycle.observe(pose, baseline: sample) {
                supplemental.append(event.seconds)
                counts.append(event.seconds)
            }
        }
        return PoseReplayRecoveryResult(
            baseline: baseline, countedAtSeconds: counts, supplementalAtSeconds: supplemental
        )
    }

    private struct Stance {
        let left: Observation
        let right: Observation
        let time: TimeInterval

        func feetAndHipsStable(_ pose: PoseReplayPose, left l: Observation?, right r: Observation?) -> Bool {
            // An ankle may still be visible when Vision loses the hip on the same side.
            for (joint, initial) in [(PoseReplayJoint.leftAnkle, left), (.rightAnkle, right)] {
                guard let point = pose.points.first(where: { $0.joint == joint && $0.confidence >= 0.5 })
                else { continue }
                let dx = point.horizontalPosition * pose.aspectRatio - initial.ankle.x
                let dy = point.verticalPosition - initial.ankle.y
                if hypot(dx, dy) > 0.20 * initial.hipAnkleHeight { return false }
            }
            guard let l, let r else { return true }
            let spanChange = (l.hipX - r.hipX) - (left.hipX - right.hipX)
            return abs(spanChange) <= 0.20 * min(left.hipAnkleHeight, right.hipAnkleHeight)
        }
    }

    private struct DepthEvidence {
        var frames = 0
        var lastVisible: TimeInterval?
        // Non-nil only after a leg switch with two depth frames and a late supporting leg.
        var delayedWitnessFrames: Int?
        static let delayedWitnessWindow: TimeInterval = 0.5
        var holding = false
        var perspectiveFrames = 0
        var explainsMiss = false
        var confirmed: Bool { frames == requiredFrames }

        mutating func observe(_ leg: Observation?, relativeTo upright: Observation,
                              other: Observation?, otherUpright: Observation,
                              selectedOther: Bool, baseline: PoseReplayDepthSample) {
            let time = baseline.seconds
            let otherDrop = other.map { 1 - $0.hipAnkleHeight / otherUpright.hipAnkleHeight } ?? 0
            let strongWitness = other.map { isStrongWitness($0, drop: otherDrop) } ?? false
            if let witnesses = delayedWitnessFrames {
                if let lastVisible, time - lastVisible <= Self.delayedWitnessWindow, strongWitness {
                    if leg == nil {
                        delayedWitnessFrames = min(2, witnesses + 1)
                        return
                    }
                    if witnesses >= 2 {
                        // The normal visible-leg depth checks below must still pass on this frame.
                        explainsMiss = true
                        delayedWitnessFrames = nil
                    } else {
                        self = Self()
                    }
                } else {
                    self = Self()
                }
            }
            if holding, let lastVisible, time - lastVisible > 0.8 { self = Self() }
            guard let leg else {
                if frames == requiredFrames - 1, selectedOther, baseline.movementReset,
                   !strongWitness, otherDrop >= 0.34, let lastVisible,
                   time - lastVisible <= Self.delayedWitnessWindow {
                    delayedWitnessFrames = 0
                    perspectiveFrames = 0
                    return
                }
                // Only suspend substantial evidence. Hidden frames never advance depth.
                guard frames >= 2, strongWitness, holding || (selectedOther && baseline.movementReset),
                      let lastVisible, time - lastVisible <= 0.8 else {
                    self = Self()
                    return
                }
                perspectiveFrames = 0
                holding = true
                explainsMiss = true
                return
            }
            lastVisible = time
            holding = false
            let drop = 1 - leg.hipAnkleHeight / upright.hipAnkleHeight
            guard passesDepth(leg), drop >= 0.44 else {
                if !confirmed { self = Self() }
                perspectiveFrames = 0
                return
            }
            // With two visible legs, demand simultaneous support throughout a full depth streak.
            if selectedOther, let other, !passesDepth(other), strongWitness {
                perspectiveFrames = min(requiredFrames, perspectiveFrames + 1)
                if perspectiveFrames == requiredFrames { explainsMiss = true }
            } else {
                perspectiveFrames = 0
            }
            if frames < requiredFrames - 1 || otherDrop >= 0.34 {
                frames = min(requiredFrames, frames + 1)
            }
        }
    }

    private static func passesDepth(_ leg: Observation) -> Bool {
        leg.kneeAngle <= thresholds.loweredThreshold
            && leg.normalizedThighHeight <= maximumThighHeight
    }

    // Only the stance, side and time survive the missing triads. All depth evidence starts over.
    private struct BilateralDropout {
        let side: BodyLeg
        let lastObserved: TimeInterval
        var awaitingFirstPair = true
        var pairedFrames = 0
        var witnessed = false
        var confirmed: Bool { pairedFrames == requiredFrames && witnessed }

        func hasVisibleSupport(in pose: PoseReplayPose) -> Bool {
            let ankle: PoseReplayJoint = side == .left ? .leftAnkle : .rightAnkle
            let oppositeHip: PoseReplayJoint = side == .left ? .rightHip : .leftHip
            return [ankle, oppositeHip, .leftKnee, .rightKnee].allSatisfy { joint in
                pose.points.contains { $0.joint == joint && $0.confidence >= 0.5 }
            }
        }

        mutating func recheck(left: Observation?, right: Observation?, stance: Stance, at time: TimeInterval) -> Bool {
            let leg = side == .left ? left : right
            let other = side == .left ? right : left
            if confirmed { return leg != nil && other != nil }
            let elapsed = time - lastObserved
            let upright = side == .left ? stance.left : stance.right
            guard elapsed <= 0.8, let leg, passesDepth(leg),
                  1 - leg.hipAnkleHeight / upright.hipAnkleHeight >= 0.44 else { return false }

            let otherUpright = side == .left ? stance.right : stance.left
            let drop = other.map { 1 - $0.hipAnkleHeight / otherUpright.hipAnkleHeight } ?? 0
            let strong = other.map { isStrongWitness($0, drop: drop) } ?? false
            if awaitingFirstPair {
                guard elapsed <= 0.25, strong else { return false }
                awaitingFirstPair = false
            }
            // A missing opposite triad breaks the streak. It cannot supply a paired depth frame.
            guard other != nil else {
                pairedFrames = 0
                witnessed = false
                return true
            }
            guard drop >= 0.34 else { return false }
            pairedFrames = min(requiredFrames, pairedFrames + 1)
            witnessed = witnessed || strong
            return true
        }
    }

    private static func isStrongWitness(_ leg: Observation, drop: Double) -> Bool {
        drop >= 0.44 || (drop >= 0.34 && leg.kneeAngle <= thresholds.loweredThreshold)
    }

    private struct Cycle {
        var stance: Stance?
        var uprightFrames = 0
        var baselineCounted = false
        var left = DepthEvidence()
        var right = DepthEvidence()
        var beforeDropout: BilateralDropout?
        var dropout: BilateralDropout?

        mutating func observe(_ pose: PoseReplayPose, baseline: PoseReplayDepthSample) -> Bool {
            let l = PoseReplayDepthAudit.observe(pose, side: .left)
            let r = PoseReplayDepthAudit.observe(pose, side: .right)
            if let stance, baseline.seconds - stance.time > 6 || !stance.feetAndHipsStable(pose, left: l, right: r) {
                self = Self()
                return false
            }
            guard !baseline.invalidGeometry else {
                self = Self()
                return false
            }
            baselineCounted = baselineCounted || baseline.counted
            if l == nil && r == nil {
                guard let candidate = beforeDropout, candidate.hasVisibleSupport(in: pose) else {
                    self = Self()
                    return false
                }
                left = DepthEvidence()
                right = DepthEvidence()
                uprightFrames = 0
                dropout = candidate
                beforeDropout = nil
                return false
            }
            if let stance, dropout != nil {
                guard dropout?.recheck(left: l, right: r, stance: stance, at: baseline.seconds) == true else {
                    self = Self()
                    return false
                }
            } else if let stance {
                left.observe(l, relativeTo: stance.left, other: r, otherUpright: stance.right,
                             selectedOther: baseline.selectedLeg == .right, baseline: baseline)
                right.observe(r, relativeTo: stance.right, other: l, otherUpright: stance.left,
                              selectedOther: baseline.selectedLeg == .left, baseline: baseline)
                beforeDropout = nil
                if let l, let r, baseline.phase == .standing, !baselineCounted {
                    if baseline.selectedLeg == .right, left.frames == requiredFrames - 1,
                       !passesDepth(r), 1 - r.hipAnkleHeight / stance.right.hipAnkleHeight >= 0.34 {
                        beforeDropout = BilateralDropout(side: .left, lastObserved: baseline.seconds)
                    } else if baseline.selectedLeg == .left, right.frames == requiredFrames - 1,
                              !passesDepth(l), 1 - l.hipAnkleHeight / stance.left.hipAnkleHeight >= 0.34 {
                        beforeDropout = BilateralDropout(side: .right, lastObserved: baseline.seconds)
                    }
                }
            }

            guard let l, let r, l.kneeAngle >= thresholds.standingThreshold,
                  r.kneeAngle >= thresholds.standingThreshold, l.hipAnkleHeight > 0, r.hipAnkleHeight > 0,
                  stance.map({ l.hipAnkleHeight >= 0.80 * $0.left.hipAnkleHeight
                      && r.hipAnkleHeight >= 0.80 * $0.right.hipAnkleHeight }) ?? true else {
                uprightFrames = 0
                return false
            }
            uprightFrames = min(requiredFrames, uprightFrames + 1)
            guard uprightFrames == requiredFrames, baseline.phase == .standing else { return false }
            // A confirmed baseline return owns this entire excursion, even if it came earlier.
            let recovered = !baselineCounted && ((left.confirmed && left.explainsMiss)
                || (right.confirmed && right.explainsMiss) || dropout?.confirmed == true)
            stance = Stance(left: l, right: r, time: baseline.seconds)
            left = DepthEvidence()
            right = DepthEvidence()
            beforeDropout = nil
            dropout = nil
            baselineCounted = false
            return recovered
        }
    }
}
#endif
