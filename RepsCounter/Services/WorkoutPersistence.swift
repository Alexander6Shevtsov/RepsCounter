import CoreData
import Foundation

@MainActor
final class WorkoutPersistence: WorkoutStoring {
    enum PersistenceError: LocalizedError {
        case conflictingIdentifier
        case invalidRecord
        case unsupportedModel

        var errorDescription: String? {
            switch self {
            case .conflictingIdentifier:
                return "Тренировка с этим идентификатором уже содержит другие данные."
            case .invalidRecord:
                return "Не удалось прочитать сохранённую тренировку."
            case .unsupportedModel:
                return "Версия хранилища тренировок не поддерживается."
            }
        }
    }

    private let coordinator: NSPersistentStoreCoordinator
    private let commit: @MainActor (NSManagedObjectContext) throws -> Void
    private let inMemory: Bool
    private let storeURL: URL
    private var isReady = false
    private(set) var initializationError: Error?

    init(
        inMemory: Bool = false,
        storeURL: URL? = nil,
        commit: (@MainActor (NSManagedObjectContext) throws -> Void)? = nil
    ) {
        let currentModel = Self.makeModel(includesIdentifier: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
        self.commit = commit ?? { context in try context.save() }
        self.inMemory = inMemory
        self.storeURL = storeURL ?? NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent("RepsCounter.sqlite")

        do {
            try ensureReady()
        } catch {
            initializationError = error
        }
    }

    func save(_ summary: WorkoutSummary) throws {
        try ensureReady()
        let context = makeContext()
        defer { context.reset() }

        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Workout")
            request.predicate = NSPredicate(format: "id == %@", summary.id as NSUUID)
            request.fetchLimit = 1
            request.includesPendingChanges = false
            if let existingRecord = try context.fetch(request).first {
                guard try Self.summary(from: existingRecord) == summary else {
                    throw PersistenceError.conflictingIdentifier
                }
                return
            }

            let record = NSEntityDescription.insertNewObject(forEntityName: "Workout", into: context)
            record.setValue(summary.id, forKey: "id")
            record.setValue(summary.date, forKey: "date")
            record.setValue(Int64(summary.duration), forKey: "duration")
            record.setValue(Int64(summary.repetitions), forKey: "repetitions")
            record.setValue(Int64(summary.sets), forKey: "sets")
            try commit(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    func history() throws -> [WorkoutSummary] {
        try ensureReady()
        let context = makeContext()
        defer { context.reset() }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Workout")
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.includesPendingChanges = false
        return try context.fetch(request).map { try Self.summary(from: $0) }
    }

    func close() throws {
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        isReady = false
    }

    private func makeContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        return context
    }

    private func ensureReady() throws {
        guard !isReady else { return }
        do {
            if coordinator.persistentStores.isEmpty {
                if inMemory {
                    _ = try coordinator.addPersistentStore(
                        type: .inMemory,
                        at: URL(fileURLWithPath: "/dev/null")
                    )
                } else {
                    try FileManager.default.createDirectory(
                        at: storeURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try migrateStoreIfNeeded(at: storeURL, currentModel: coordinator.managedObjectModel)
                    _ = try coordinator.addPersistentStore(type: .sqlite, at: storeURL)
                }
            }
            try assignMissingIdentifiers()
            initializationError = nil
            isReady = true
        } catch {
            initializationError = error
            throw error
        }
    }

    private func assignMissingIdentifiers() throws {
        let context = makeContext()
        defer { context.reset() }

        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Workout")
            request.predicate = NSPredicate(format: "id == nil")
            for record in try context.fetch(request) {
                record.setValue(UUID(), forKey: "id")
            }
            if context.hasChanges { try commit(context) }
        } catch {
            context.rollback()
            throw error
        }
    }

    private func migrateStoreIfNeeded(at storeURL: URL, currentModel: NSManagedObjectModel) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        guard !currentModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { return }
        let legacyModel = Self.makeModel(includesIdentifier: false)
        guard legacyModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
            throw PersistenceError.unsupportedModel
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RepsCounter-Migration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let migratedURL = directory.appendingPathComponent("RepsCounter.sqlite")
        try autoreleasepool {
            let mapping = try NSMappingModel.inferredMappingModel(
                forSourceModel: legacyModel,
                destinationModel: currentModel
            )
            let migration = NSMigrationManager(sourceModel: legacyModel, destinationModel: currentModel)
            try migration.migrateStore(
                from: storeURL,
                type: .sqlite,
                mapping: mapping,
                to: migratedURL,
                type: .sqlite
            )
        }
        try coordinator.replacePersistentStore(
            at: storeURL,
            withPersistentStoreFrom: migratedURL,
            type: .sqlite
        )
    }

    private static func summary(from record: NSManagedObject) throws -> WorkoutSummary {
        guard
            let identifier = record.value(forKey: "id") as? UUID,
            let date = record.value(forKey: "date") as? Date,
            let duration = record.value(forKey: "duration") as? NSNumber,
            let repetitions = record.value(forKey: "repetitions") as? NSNumber,
            let sets = record.value(forKey: "sets") as? NSNumber
        else {
            throw PersistenceError.invalidRecord
        }
        return WorkoutSummary(
            id: identifier,
            date: date,
            duration: duration.intValue,
            repetitions: repetitions.intValue,
            sets: sets.intValue
        )
    }

    private static func makeModel(includesIdentifier: Bool) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let workout = NSEntityDescription()
        workout.name = "Workout"
        workout.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        var properties: [NSPropertyDescription] = [
            attribute("date", type: .dateAttributeType),
            attribute("duration", type: .integer64AttributeType),
            attribute("repetitions", type: .integer64AttributeType),
            attribute("sets", type: .integer64AttributeType)
        ]
        if includesIdentifier {
            properties.append(attribute("id", type: .UUIDAttributeType, isOptional: true))
        }
        workout.properties = properties
        model.entities = [workout]
        return model
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        isOptional: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        return attribute
    }
}
