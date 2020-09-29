import XCTest
import CoreData

@testable import Storage

/// Tests for migrating from a specific model version to another.
///
/// Ideally, we should have a test for every new model version. There can also be more than
/// one test between 2 versions if there are many cases being tested.
///
/// ## Notes
///
/// In general, we should avoid using the entity classes like `Product` or `Order`. These classes
/// may **change** in the future. And if they do, the migration tests would have to be changed.
/// There's a risk that the migration tests would no longer be correct if this happens.
///
/// That said, it is understandable that we are sometimes under pressure to finish features that
/// this may not be economical.
///
final class MigrationTests: XCTestCase {
    private var modelsInventory: ManagedObjectModelsInventory!

    /// URLs of SQLite stores created using `makePersistentStore()`.
    ///
    /// These will be deleted during tear down.
    private var createdStoreURLs = Set<URL>()

    override func setUpWithError() throws {
        try super.setUpWithError()
        modelsInventory = try .from(packageName: "WooCommerce", bundle: Bundle(for: CoreDataManager.self))
    }

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        let knownExtensions = ["sqlite-shm", "sqlite-wal"]
        try createdStoreURLs.forEach { url in
            try fileManager.removeItem(at: url)

            try knownExtensions.forEach { ext in
                if fileManager.fileExists(atPath: url.appendingPathExtension(ext).path) {
                    try fileManager.removeItem(at: url.appendingPathExtension(ext))
                }
            }
        }

        modelsInventory = nil

        try super.tearDownWithError()
    }

    func test_migrating_from_31_to_32_renames_Attribute_to_GenericAttribute() throws {
        // Given
        let container = try startPersistentContainer("Model 31")

        let attribute = container.viewContext.insert(entityName: "Attribute", properties: [
            "id": 9_753_134,
            "key": "voluptatem",
            "value": "veritatis"
        ])
        let variation = insertProductVariation(to: container.viewContext)
        variation.mutableOrderedSetValue(forKey: "attributes").add(attribute)

        try container.viewContext.save()

        XCTAssertEqual(try container.viewContext.count(entityName: "Attribute"), 1)
        XCTAssertEqual(try container.viewContext.count(entityName: "ProductVariation"), 1)

        // When
        let migratedContainer = try migrate(container, to: "Model 32")

        // Then
        XCTAssertNil(NSEntityDescription.entity(forEntityName: "Attribute", in: migratedContainer.viewContext))
        XCTAssertEqual(try migratedContainer.viewContext.count(entityName: "GenericAttribute"), 1)
        XCTAssertEqual(try migratedContainer.viewContext.count(entityName: "ProductVariation"), 1)

        let migratedAttribute = try XCTUnwrap(migratedContainer.viewContext.allObjects(entityName: "GenericAttribute").first)
        XCTAssertEqual(migratedAttribute.value(forKey: "id") as? Int, 9_753_134)
        XCTAssertEqual(migratedAttribute.value(forKey: "key") as? String, "voluptatem")
        XCTAssertEqual(migratedAttribute.value(forKey: "value") as? String, "veritatis")

        // The "attributes" relationship should have been migrated too
        let migratedVariation = try XCTUnwrap(migratedContainer.viewContext.allObjects(entityName: "ProductVariation").first)
        let migratedVariationAttributes = migratedVariation.mutableOrderedSetValue(forKey: "attributes")
        XCTAssertEqual(migratedVariationAttributes.count, 1)
        XCTAssertEqual(migratedVariationAttributes.firstObject as? NSManagedObject, migratedAttribute)

        // The migrated attribute can be accessed using the newly renamed `GenericAttribute` class.
        let genericAttribute = try XCTUnwrap(migratedContainer.viewContext.firstObject(ofType: GenericAttribute.self))
        XCTAssertEqual(genericAttribute.id, 9_753_134)
        XCTAssertEqual(genericAttribute.key, "voluptatem")
        XCTAssertEqual(genericAttribute.value, "veritatis")
    }

    /// Model 32 = the base version
    /// Model 33 = adds testProperty (added by Mary)
    /// Model 34 = PRODUCTION version. Based on Model 33 (before testProperty33 was added by John).
    ///            This is what got deployed to production.
    /// Model 33 = DEVELOP version. Adds testProperty33 (added by John). This is the second
    ///            deployment to production.
    ///
    func test_production_version_is_not_compatible_with_develop_version() throws {
        // Given
        let baseModel = try XCTUnwrap(modelsInventory.model(for: .init(name: "Model 32")))
        let containerWithBaseVersion = try startPersistentContainer("Model 32")
        let storeURL = try XCTUnwrap(containerWithBaseVersion.persistentStoreDescriptions.first?.url)

        // When
        let productionModel = try XCTUnwrap(modelsInventory.model(for: .init(name: "Model 34")))
        let mappingFromBaseToProduction = try NSMappingModel.inferredMappingModel(forSourceModel: baseModel, destinationModel: productionModel)

        // Migrate directly from base version to production version
        let migrator = NSMigrationManager(sourceModel: baseModel, destinationModel: productionModel)
        try migrator.migrateStore(from: storeURL,
                                  sourceType: NSSQLiteStoreType, options: nil,
                                  with: mappingFromBaseToProduction,
                                  toDestinationURL: storeURL,
                                  destinationType: NSSQLiteStoreType,
                                  destinationOptions: nil)

        let containerWithProductionVersion = makePersistentContainer(storeURL: storeURL, model: productionModel)
        let loadingError: Error? = try waitFor { promise in
            containerWithProductionVersion.loadPersistentStores { _, error in
                promise(error)
            }
        }
        XCTAssertNil(loadingError)

        // Then
        let latestModelInDevelop = try XCTUnwrap(modelsInventory.model(for: .init(name: "Model 33")))
        let persistentStoreWithProductionVersion =
            try XCTUnwrap(containerWithProductionVersion.persistentStoreCoordinator.persistentStores.first)

        // The production database is not compatible with the latest in develop
        XCTAssertFalse(latestModelInDevelop.isConfiguration(withName: nil,
                                                            compatibleWithStoreMetadata: persistentStoreWithProductionVersion.metadata))

        // Confidence-check: The production database is only compatible with the last used model
        XCTAssertTrue(productionModel.isConfiguration(withName: nil,
                                                      compatibleWithStoreMetadata: persistentStoreWithProductionVersion.metadata))
    }
}

// MARK: - Persistent Store Setup and Migrations

private extension MigrationTests {
    /// Create a new Sqlite file and load it. Returns the loaded `NSPersistentContainer`.
    func startPersistentContainer(_ versionName: String) throws -> NSPersistentContainer {
        let storeURL = try XCTUnwrap(NSURL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)?
            .appendingPathExtension("sqlite"))
        let model = try XCTUnwrap(modelsInventory.model(for: .init(name: versionName)))
        let container = makePersistentContainer(storeURL: storeURL, model: model)

        let loadingError: Error? = try waitFor { promise in
            container.loadPersistentStores { _, error in
                promise(error)
            }
        }
        XCTAssertNil(loadingError)

        return container
    }

    /// Migrate the existing `container` to the model with name `versionName`.
    ///
    /// This disconnects the given `container` from the `NSPersistentStore` (SQLite) to avoid
    /// warnings pertaining to having two `NSPersistentContainer` using the same SQLite file.
    /// The `container.viewContext` and any created `NSManagedObjects` can still be used but
    /// they will not be attached to the SQLite database so watch out for that. XD
    ///
    /// - Returns: A new `NSPersistentContainer` instance using the new `NSManagedObjectModel`
    ///            pointed to by `versionName`.
    ///
    func migrate(_ container: NSPersistentContainer, to versionName: String) throws -> NSPersistentContainer {
        let storeDescription = try XCTUnwrap(container.persistentStoreDescriptions.first)
        let storeURL = try XCTUnwrap(storeDescription.url)
        let targetModel = try XCTUnwrap(modelsInventory.model(for: .init(name: versionName)))

        // Unload the currently loaded persistent store to avoid Sqlite warnings when we create
        // another NSPersistentContainer later after the upgrade.
        let persistentStore = try XCTUnwrap(container.persistentStoreCoordinator.persistentStore(for: storeURL))
        try container.persistentStoreCoordinator.remove(persistentStore)

        // Migrate the store
        let migrator = CoreDataIterativeMigrator(modelsInventory: modelsInventory)
        let (isMigrationSuccessful, _) =
            try migrator.iterativeMigrate(sourceStore: storeURL, storeType: storeDescription.type, to: targetModel)
        XCTAssertTrue(isMigrationSuccessful)

        // Load a new container
        let migratedContainer = makePersistentContainer(storeURL: storeURL, model: targetModel)
        let loadingError: Error? = try waitFor { promise in
            migratedContainer.loadPersistentStores { _, error in
                promise(error)
            }
        }
        XCTAssertNil(loadingError)

        return migratedContainer
    }

    func makePersistentContainer(storeURL: URL, model: NSManagedObjectModel) -> NSPersistentContainer {
        let description: NSPersistentStoreDescription = {
            let description = NSPersistentStoreDescription(url: storeURL)
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = false
            description.type = NSSQLiteStoreType
            return description
        }()

        let container = NSPersistentContainer(name: "ContainerName", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]

        createdStoreURLs.insert(storeURL)

        return container
    }
}

// MARK: - Entity Helpers
//

private extension MigrationTests {
    /// Inserts a `ProductVariation` entity, providing default values for the required properties.
    @discardableResult
    func insertProductVariation(to context: NSManagedObjectContext) -> NSManagedObject {
        context.insert(entityName: "ProductVariation", properties: [
            "dateCreated": Date(),
            "backordered": false,
            "backordersAllowed": false,
            "backordersKey": "",
            "permalink": "",
            "price": "",
            "statusKey": "",
            "stockStatusKey": "",
            "taxStatusKey": ""
        ])
    }
}