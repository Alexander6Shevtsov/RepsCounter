import XCTest
@testable import RepsCounter

final class WorkoutPersistenceTests: XCTestCase {
    func testSavesWorkoutAndLoadsHistory() throws {
        let persistence = WorkoutPersistence(inMemory: true)
        let summary = WorkoutSummary(date: Date(), duration: 75, repetitions: 12, sets: 1)
        try persistence.save(summary)
        let workouts = try persistence.history()
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.repetitions, 12)
        XCTAssertEqual(workouts.first?.sets, 1)
    }
}
