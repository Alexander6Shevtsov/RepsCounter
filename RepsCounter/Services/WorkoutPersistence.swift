import CoreData
import Foundation

struct WorkoutSummary {
    let date: Date
    let duration: Int
    let repetitions: Int
    let sets: Int
}

final class WorkoutPersistence {
    private let container: NSPersistentContainer
    private(set) var initializationError: Error?

    init(inMemory: Bool = false) {
        let model = NSManagedObjectModel()
        let workout = NSEntityDescription()
        workout.name = "Workout"
        workout.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        workout.properties = [
            Self.attribute("date", type: .dateAttributeType),
            Self.attribute("duration", type: .integer64AttributeType),
            Self.attribute("repetitions", type: .integer64AttributeType),
            Self.attribute("sets", type: .integer64AttributeType)
        ]
        model.entities = [workout]
        container = NSPersistentContainer(name: "RepsCounter", managedObjectModel: model)
        if inMemory { container.persistentStoreDescriptions.first?.type = NSInMemoryStoreType }
        container.loadPersistentStores { [weak self] _, error in
            self?.initializationError = error
        }
    }

    func save(_ summary: WorkoutSummary) throws {
        if let initializationError { throw initializationError }
        let context = container.viewContext
        guard let entity = NSEntityDescription.entity(forEntityName: "Workout", in: context) else {
            throw NSError(domain: "RepsCounter.Persistence", code: 1)
        }
        let record = NSManagedObject(entity: entity, insertInto: context)
        record.setValue(summary.date, forKey: "date")
        record.setValue(Int64(summary.duration), forKey: "duration")
        record.setValue(Int64(summary.repetitions), forKey: "repetitions")
        record.setValue(Int64(summary.sets), forKey: "sets")
        try context.save()
    }

    func history() throws -> [WorkoutSummary] {
        if let initializationError { throw initializationError }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Workout")
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return try container.viewContext.fetch(request).compactMap { record in
            guard let date = record.value(forKey: "date") as? Date else { return nil }
            return WorkoutSummary(
                date: date,
                duration: Int(record.value(forKey: "duration") as? Int64 ?? 0),
                repetitions: Int(record.value(forKey: "repetitions") as? Int64 ?? 0),
                sets: Int(record.value(forKey: "sets") as? Int64 ?? 0)
            )
        }
    }

    private static func attribute(_ name: String, type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = false
        return attribute
    }
}
