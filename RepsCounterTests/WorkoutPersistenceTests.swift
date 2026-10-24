import CoreData
import XCTest
@testable import RepsCounter

final class WorkoutPersistenceTests: XCTestCase {
    private enum SimulatedError: Error {
        case commitFailed
    }

    @MainActor
    func testSavesWorkoutAndLoadsHistory() throws {
        try autoreleasepool {
            let persistence = WorkoutPersistence(inMemory: true)
            defer { XCTAssertNoThrow(try persistence.close()) }
            let summary = WorkoutSummary(date: Date(), duration: 75, repetitions: 12, sets: 1)
            try persistence.save(summary)
            let workouts = try persistence.history()
            XCTAssertEqual(workouts.count, 1)
            XCTAssertEqual(workouts.first?.repetitions, 12)
            XCTAssertEqual(workouts.first?.sets, 1)
            XCTAssertEqual(workouts.first, summary)
        }
    }

    @MainActor
    func testFailedCommitLeavesHistoryAndContextClean() throws {
        try autoreleasepool {
            let location = try makeStoreURL()
            var failedContext: NSManagedObjectContext?
            let persistence = WorkoutPersistence(storeURL: location, commit: { context in
                XCTAssertEqual(context.insertedObjects.count, 1)
                failedContext = context
                throw SimulatedError.commitFailed
            })
            defer { XCTAssertNoThrow(try persistence.close()) }
            let summary = WorkoutSummary(date: Date(), duration: 75, repetitions: 12, sets: 1)

            XCTAssertThrowsError(try persistence.save(summary))
            XCTAssertTrue(try persistence.history().isEmpty)
            XCTAssertFalse(try XCTUnwrap(failedContext).hasChanges)
            let reopenedRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try reopenedRepository.close()) }
            XCTAssertTrue(try reopenedRepository.history().isEmpty)
        }
    }

    @MainActor
    func testRetryAfterFailedCommitSavesExactlyOnce() throws {
        try autoreleasepool {
            var shouldFail = true
            let persistence = WorkoutPersistence(inMemory: true, commit: { context in
                if shouldFail {
                    shouldFail = false
                    throw SimulatedError.commitFailed
                }
                try context.save()
            })
            defer { XCTAssertNoThrow(try persistence.close()) }
            let summary = WorkoutSummary(date: Date(), duration: 75, repetitions: 12, sets: 1)

            XCTAssertThrowsError(try persistence.save(summary))
            try persistence.save(summary)
            try persistence.save(summary)

            XCTAssertEqual(try persistence.history(), [summary])
        }
    }

    @MainActor
    func testReportedFailureAfterCommitCanBeRetriedWithoutAnotherCommit() throws {
        try autoreleasepool {
            let location = try makeStoreURL()
            var commitCount = 0
            let persistence = WorkoutPersistence(storeURL: location, commit: { context in
                commitCount += 1
                try context.save()
                throw SimulatedError.commitFailed
            })
            defer { XCTAssertNoThrow(try persistence.close()) }
            let summary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_000_000), duration: 75, repetitions: 12, sets: 1
            )

            XCTAssertThrowsError(try persistence.save(summary))
            XCTAssertEqual(try persistence.history(), [summary])
            try persistence.save(summary)
            XCTAssertEqual(commitCount, 1)

            let reopenedRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try reopenedRepository.close()) }
            try reopenedRepository.save(summary)
            XCTAssertEqual(try reopenedRepository.history(), [summary])
        }
    }

    @MainActor
    func testRepeatedIdentifierDoesNotCreateAnotherWorkout() throws {
        try autoreleasepool {
            let persistence = WorkoutPersistence(inMemory: true)
            defer { XCTAssertNoThrow(try persistence.close()) }
            let summary = WorkoutSummary(date: Date(), duration: 75, repetitions: 12, sets: 1)

            try persistence.save(summary)
            try persistence.save(summary)

            XCTAssertEqual(try persistence.history(), [summary])
        }
    }

    @MainActor
    func testRepeatedIdentifierWithDifferentPayloadIsRejected() throws {
        try autoreleasepool {
            let persistence = WorkoutPersistence(inMemory: true)
            defer { XCTAssertNoThrow(try persistence.close()) }
            let summary = WorkoutSummary(date: Date(), duration: 75, repetitions: 12, sets: 1)
            let conflicting = WorkoutSummary(
                id: summary.id,
                date: summary.date,
                duration: summary.duration,
                repetitions: 24,
                sets: 2
            )
            try persistence.save(summary)

            XCTAssertThrowsError(try persistence.save(conflicting))
            XCTAssertEqual(try persistence.history(), [summary])
        }
    }

    @MainActor
    func testDistinctIdentifiersPreserveOtherwiseIdenticalWorkouts() throws {
        try autoreleasepool {
            let persistence = WorkoutPersistence(inMemory: true)
            defer { XCTAssertNoThrow(try persistence.close()) }
            let date = Date()
            let firstSummary = WorkoutSummary(date: date, duration: 75, repetitions: 12, sets: 1)
            let secondSummary = WorkoutSummary(date: date, duration: 75, repetitions: 12, sets: 1)

            try persistence.save(firstSummary)
            try persistence.save(secondSummary)

            let workouts = try persistence.history()
            XCTAssertEqual(workouts.count, 2)
            XCTAssertEqual(Set(workouts.map(\.id)), [firstSummary.id, secondSummary.id])
        }
    }

    @MainActor
    func testSQLiteReopenAndRepositoryInstancesKeepIdentifierStable() throws {
        try autoreleasepool {
            let location = try makeStoreURL()
            let summary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_000_000), duration: 75, repetitions: 12, sets: 1
            )
            let firstRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try firstRepository.close()) }
            try firstRepository.save(summary)

            let secondRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try secondRepository.close()) }
            try secondRepository.save(summary)
            XCTAssertEqual(try secondRepository.history(), [summary])
            XCTAssertEqual(try firstRepository.history(), [summary])

            let reopenedRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try reopenedRepository.close()) }
            XCTAssertEqual(try reopenedRepository.history(), [summary])
        }
    }

    @MainActor
    func testMigratesLegacySQLiteWithoutLosingHistoryAndKeepsBackfilledIdentifiers() throws {
        try autoreleasepool {
            let location = try makeStoreURL()
            let olderSummary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_000_000), duration: 75, repetitions: 12, sets: 1
            )
            let newerSummary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_001_000), duration: 180, repetitions: 24, sets: 2
            )
            try createLegacyStore(at: location, summaries: [olderSummary, newerSummary])

            let migratedRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try migratedRepository.close()) }
            let migratedHistory = try migratedRepository.history()
            XCTAssertEqual(migratedHistory.map(\.date), [newerSummary.date, olderSummary.date])
            XCTAssertEqual(migratedHistory.map(\.duration), [180, 75])
            XCTAssertEqual(migratedHistory.map(\.repetitions), [24, 12])
            XCTAssertEqual(migratedHistory.map(\.sets), [2, 1])
            XCTAssertEqual(Set(migratedHistory.map(\.id)).count, 2)

            let newestSummary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_002_000), duration: 240, repetitions: 36, sets: 3
            )
            try migratedRepository.save(newestSummary)
            let reopenedRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try reopenedRepository.close()) }

            XCTAssertEqual(try reopenedRepository.history(), [newestSummary] + migratedHistory)
            try reopenedRepository.save(newestSummary)
            XCTAssertEqual(try reopenedRepository.history().count, 3)
        }
    }

    @MainActor
    func testFailedLegacyBackfillCanBeRetriedWithoutLosingRecords() throws {
        try autoreleasepool {
            let location = try makeStoreURL()
            let summary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_000_000), duration: 75, repetitions: 12, sets: 1
            )
            try createLegacyStore(at: location, summaries: [summary])
            let failedRepository = WorkoutPersistence(storeURL: location, commit: { context in
                XCTAssertTrue(context.hasChanges)
                throw SimulatedError.commitFailed
            })
            defer { XCTAssertNoThrow(try failedRepository.close()) }

            XCTAssertNotNil(failedRepository.initializationError)
            XCTAssertThrowsError(try failedRepository.history())
            let reopenedRepository = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try reopenedRepository.close()) }
            let workouts = try reopenedRepository.history()
            XCTAssertEqual(workouts.count, 1)
            XCTAssertEqual(workouts.first?.date, summary.date)
            XCTAssertEqual(workouts.first?.duration, summary.duration)
            XCTAssertEqual(workouts.first?.repetitions, summary.repetitions)
            XCTAssertEqual(workouts.first?.sets, summary.sets)
        }
    }

    @MainActor
    func testSameRepositoryRecoversAfterTemporaryLegacyBackfillFailure() throws {
        try autoreleasepool {
            let location = try makeStoreURL()
            let legacySummary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_000_000), duration: 75, repetitions: 12, sets: 1
            )
            try createLegacyStore(at: location, summaries: [legacySummary])
            var shouldFail = true
            let persistence = WorkoutPersistence(storeURL: location, commit: { context in
                if shouldFail { throw SimulatedError.commitFailed }
                try context.save()
            })
            defer { XCTAssertNoThrow(try persistence.close()) }
            XCTAssertNotNil(persistence.initializationError)
            XCTAssertThrowsError(try persistence.history())
            shouldFail = false
            let newSummary = WorkoutSummary(
                date: Date(timeIntervalSince1970: 1_700_001_000), duration: 180, repetitions: 24, sets: 2
            )

            try persistence.save(newSummary)
            try persistence.save(newSummary)

            XCTAssertNil(persistence.initializationError)
            let workouts = try persistence.history()
            XCTAssertEqual(workouts.count, 2)
            XCTAssertEqual(workouts.first, newSummary)
            XCTAssertEqual(workouts.last?.date, legacySummary.date)
            XCTAssertEqual(workouts.last?.repetitions, legacySummary.repetitions)
        }
    }

    @MainActor
    func testInitializationFailurePreservesUnreadableStore() throws {
        try autoreleasepool {
            let location = try makeStoreURL()
            let originalData = Data("Unreadable legacy workout store".utf8)
            try originalData.write(to: location)
            let persistence = WorkoutPersistence(storeURL: location)
            defer { XCTAssertNoThrow(try persistence.close()) }
            let summary = WorkoutSummary(date: Date(), duration: 75, repetitions: 12, sets: 1)

            XCTAssertNotNil(persistence.initializationError)
            XCTAssertThrowsError(try persistence.history())
            XCTAssertThrowsError(try persistence.save(summary))
            XCTAssertEqual(try Data(contentsOf: location), originalData)
        }
    }

    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("RepsCounter.sqlite")
    }

    @MainActor
    private func createLegacyStore(at storeURL: URL, summaries: [WorkoutSummary]) throws {
        try autoreleasepool {
            let model = NSManagedObjectModel()
            let workout = NSEntityDescription()
            workout.name = "Workout"
            workout.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            let definitions: [(String, NSAttributeType)] = [
                ("date", .dateAttributeType),
                ("duration", .integer64AttributeType),
                ("repetitions", .integer64AttributeType),
                ("sets", .integer64AttributeType)
            ]
            workout.properties = definitions.map { definition in
                let attribute = NSAttributeDescription()
                attribute.name = definition.0
                attribute.attributeType = definition.1
                attribute.isOptional = false
                return attribute
            }
            model.entities = [workout]
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(type: .sqlite, at: storeURL)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator

            for summary in summaries {
                let record = NSEntityDescription.insertNewObject(forEntityName: "Workout", into: context)
                record.setValue(summary.date, forKey: "date")
                record.setValue(Int64(summary.duration), forKey: "duration")
                record.setValue(Int64(summary.repetitions), forKey: "repetitions")
                record.setValue(Int64(summary.sets), forKey: "sets")
            }
            try context.save()
            context.reset()
            try coordinator.remove(store)
        }
    }
}
