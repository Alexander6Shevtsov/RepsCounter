import Foundation

struct WorkoutSummary: Equatable, Sendable {
    let id: UUID
    let date: Date
    let duration: Int
    let repetitions: Int
    let sets: Int

    init(id: UUID = UUID(), date: Date, duration: Int, repetitions: Int, sets: Int) {
        self.id = id
        self.date = date
        self.duration = duration
        self.repetitions = repetitions
        self.sets = sets
    }
}

@MainActor
protocol WorkoutStoring {
    func save(_ summary: WorkoutSummary) throws
    func history() throws -> [WorkoutSummary]
}
