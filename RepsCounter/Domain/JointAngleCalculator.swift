import CoreGraphics
import Foundation

enum JointAngleCalculator {
    static func angle(first: CGPoint, vertex: CGPoint, third: CGPoint) -> Double? {
        let firstVectorX = Double(first.x - vertex.x)
        let firstVectorY = Double(first.y - vertex.y)
        let thirdVectorX = Double(third.x - vertex.x)
        let thirdVectorY = Double(third.y - vertex.y)
        let firstLength = hypot(firstVectorX, firstVectorY)
        let thirdLength = hypot(thirdVectorX, thirdVectorY)

        guard firstLength > 0.0001, thirdLength > 0.0001 else {
            return nil
        }

        let normalizedDotProduct = (firstVectorX * thirdVectorX + firstVectorY * thirdVectorY)
            / (firstLength * thirdLength)
        let clampedDotProduct = min(1, max(-1, normalizedDotProduct))
        return acos(clampedDotProduct) * 180 / .pi
    }
}
