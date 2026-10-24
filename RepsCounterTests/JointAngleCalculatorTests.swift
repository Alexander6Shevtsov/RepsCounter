import CoreGraphics
import XCTest
@testable import RepsCounter

final class JointAngleCalculatorTests: XCTestCase {
    func testStraightLegMeasures180Degrees() {
        let angle = JointAngleCalculator.angle(
            first: CGPoint(x: 0, y: 1),
            vertex: CGPoint(x: 0, y: 0),
            third: CGPoint(x: 0, y: -1)
        )
        XCTAssertEqual(angle ?? 0, 180, accuracy: 0.001)
    }

    func testRightAngleMeasures90Degrees() {
        let angle = JointAngleCalculator.angle(
            first: CGPoint(x: 0, y: 1),
            vertex: CGPoint(x: 0, y: 0),
            third: CGPoint(x: 1, y: 0)
        )
        XCTAssertEqual(angle ?? 0, 90, accuracy: 0.001)
    }

    func testCoincidentJointsReturnNil() {
        XCTAssertNil(JointAngleCalculator.angle(
            first: .zero, vertex: .zero, third: CGPoint(x: 1, y: 0)
        ))
    }
}
