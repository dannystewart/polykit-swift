//
//  PolyBaseRegistry.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase
import SwiftData

// MARK: - PolyParentRelation

/// Defines a parent-child relationship for hierarchy bumping.
///
/// When a child entity changes, its parent's version is bumped
/// to signal that something in its subtree changed. This enables
/// efficient hierarchical reconciliation.
public struct PolyParentRelation<Child: PolySyncable, Parent: PolySyncable>: Sendable {
    /// Key path to the parent ID on the child entity
    let parentIDKeyPath: KeyPath<Child, String> & Sendable

    /// The parent entity type
    let parentType: Parent.Type

    /// Get the parent ID from a child entity
    public func getParentID(from child: Child) -> String {
        child[keyPath: parentIDKeyPath]
    }
}

// MARK: - AnyParentRelation

/// Type-erased parent relation for storage.
public struct AnyParentRelation: Sendable {
    /// The parent type name (used to look up table name from registry)
    let parentTypeName: String

    private let _getParentID: @Sendable (Any) -> String?

    /// Resolve the parent table name from the registry.
    /// This is resolved lazily because the parent may not be registered when the child is registered.
    public var parentTableName: String {
        guard let parentConfig = PolyBaseRegistry.shared.config(forTypeName: parentTypeName) else {
            polyWarning("AnyParentRelation: Parent type '\(parentTypeName)' not registered")
            return ""
        }
        return parentConfig.tableName
    }

    public init<Child: PolySyncable, Parent: PolySyncable>(
        _ relation: PolyParentRelation<Child, Parent>,
    ) {
        parentTypeName = String(describing: Parent.self)
        _getParentID = { entity in
            guard let child = entity as? Child else { return nil }
            return relation.getParentID(from: child)
        }
    }

    public func getParentID(from entity: Any) -> String? {
        _getParentID(entity)
    }
}

// MARK: - PolyEntityConfig

/// Configuration for a syncable entity type.
///
/// Created during entity registration and used by the sync engine
/// to push, pull, and reconcile entities.
public final class PolyEntityConfig<Entity: PolySyncable>: @unchecked Sendable {
    /// The Supabase table name
    public var tableName: String = ""

    /// Field mappings from Swift properties to Supabase columns
    public var fields: [PolyFieldMapping<Entity>] = []

    /// Notification to post when entities of this type change
    public var notification: Notification.Name?

    /// Column name for user_id (if RLS is used)
    public var userIDColumn: String = "user_id"

    /// Whether to include user_id in pushes (default: true for RLS)
    public var includeUserID: Bool = true

    /// Custom conflict resolution rules (optional)
    public var conflictRules: PolyConflictRules = .default

    /// Factory closure to create new entities from remote records.
    ///
    /// Required for reconciliation to create entities that exist remotely but not locally.
    /// The factory should:
    /// 1. Create the entity from the record
    /// 2. Insert it into the context
    /// 3. Return the created entity
    ///
    /// ```swift
    /// config.factory = { record, context in
    ///     let item = Item(
    ///         id: record["id"]!.stringValue!,
    ///         title: record["title"]?.stringValue ?? ""
    ///     )
    ///     context.insert(item)
    ///     return item
    /// }
    /// ```
    public var factory: ((_ record: [String: AnyJSON], _ context: ModelContext) throws -> Entity)?

    /// Parent relation for hierarchy bumping (optional)
    private var _parentRelation: AnyParentRelation?

    /// Get the parent relation (if any).
    public var parentRelation: AnyParentRelation? { _parentRelation }

    public init() {}

    /// Set a parent relation for hierarchy bumping.
    ///
    /// When this entity changes, the parent's version will be bumped.
    ///
    /// ```swift
    /// config.setParent(\.conversationID, entityType: Conversation.self)
    /// ```
    public func setParent<Parent: PolySyncable>(
        _ keyPath: KeyPath<Entity, String> & Sendable,
        entityType _: Parent.Type,
    ) {
        let relation = PolyParentRelation<Entity, Parent>(
            parentIDKeyPath: keyPath,
            parentType: Parent.self)
        // Table name is resolved lazily from the registry when accessed
        _parentRelation = AnyParentRelation(relation)
    }
}

// MARK: - PolyConflictRules

/// Custom conflict resolution rules for an entity type.
public struct PolyConflictRules: Sendable {
    public static let `default`: PolyConflictRules = .init(
        protectNonEmptyContent: true,
        protectedFields: [],
        customValidator: nil,
    )

    /// Never overwrite non-empty content with empty
    public var protectNonEmptyContent: Bool

    /// Field names to protect from being overwritten with empty values
    public var protectedFields: Set<String>

    /// Custom validation before accepting remote changes
    /// Return false to reject the remote change
    public var customValidator: (@Sendable (_ local: Any, _ remote: [String: AnyJSON]) -> Bool)?

    public init(
        protectNonEmptyContent: Bool = true,
        protectedFields: Set<String> = [],
        customValidator: (@Sendable (_ local: Any, _ remote: [String: AnyJSON]) -> Bool)? = nil,
    ) {
        self.protectNonEmptyContent = protectNonEmptyContent
        self.protectedFields = protectedFields
        self.customValidator = customValidator
    }
}

// MARK: - AnyEntityConfig

/// Type-erased entity configuration for storage.
public final class AnyEntityConfig: @unchecked Sendable {
    public let tableName: String
    public let entityTypeName: String
    public let notification: Notification.Name?
    public let parentRelation: AnyParentRelation?
    public let userIDColumn: String
    public let includeUserID: Bool
    public let conflictRules: PolyConflictRules

    private let _fields: [AnyFieldMapping]
    private let _entityType: Any.Type
    private let _factory: ((_ record: [String: AnyJSON], _ context: ModelContext) throws -> Any)?

    /// Get all field mappings.
    public var fields: [AnyFieldMapping] { _fields }

    /// Whether this entity has a factory for creating new instances from remote records.
    public var hasFactory: Bool { _factory != nil }

    public init<Entity: PolySyncable>(_ config: PolyEntityConfig<Entity>) {
        tableName = config.tableName
        entityTypeName = String(describing: Entity.self)
        notification = config.notification
        parentRelation = config.parentRelation
        userIDColumn = config.userIDColumn
        includeUserID = config.includeUserID
        conflictRules = config.conflictRules
        _fields = config.fields.map { AnyFieldMapping($0) }
        _entityType = Entity.self

        // Type-erase the factory
        if let typedFactory = config.factory {
            _factory = { record, context in
                try typedFactory(record, context)
            }
        } else {
            _factory = nil
        }
    }

    /// Check if an entity is of this config's type.
    public func matches(_ entity: Any) -> Bool {
        type(of: entity) == _entityType
    }

    /// Get a field mapping by column name.
    public func field(forColumn column: String) -> AnyFieldMapping? {
        _fields.first { $0.columnName == column }
    }

    /// Create a new entity from a remote record using the registered factory.
    ///
    /// - Parameters:
    ///   - record: The remote record from Supabase
    ///   - context: The model context to insert into
    /// - Returns: The created entity
    /// - Throws: If no factory is registered or creation fails
    public func createEntity(from record: [String: AnyJSON], context: ModelContext) throws -> Any {
        guard let factory = _factory else {
            throw PolyRegistryError.noFactory(entityTypeName)
        }
        return try factory(record, context)
    }
}

// MARK: - PolyRegistryError

/// Errors from registry operations.
public enum PolyRegistryError: LocalizedError {
    case noFactory(String)

    public var errorDescription: String? {
        switch self {
        case let .noFactory(typeName):
            "No factory registered for entity type '\(typeName)'. Add a factory closure during registration."
        }
    }
}

// MARK: - PolyBaseRegistry

/// Central registry for syncable entity types.
///
/// Apps register their entity types at startup, providing table names,
/// field mappings, and optional parent relations.
///
/// ## Usage
///
/// ```swift
/// // In app startup:
/// PolyBaseRegistry.shared.register(Message.self) { config in
///     config.tableName = "messages"
///     config.fields = [
///         .map(\.content, to: "content", encrypted: true),
///         .map(\.conversationID, to: "conversation_id"),
///         .map(\.role, to: "role"),
///         .map(\.messageTime, to: "message_time"),
///     ]
///     config.setParent(\.conversationID, entityType: Conversation.self)
///     config.notification = .messagesDidChange
/// }
/// ```
public final class PolyBaseRegistry: @unchecked Sendable {
    public static let shared: PolyBaseRegistry = .init()

    private var configs: [String: AnyEntityConfig] = [:]
    private var tableToType: [String: String] = [:]
    private let lock: NSLock = .init()

    /// Get all registered table names.
    public var registeredTables: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tableToType.keys)
    }

    /// Get all registered entity type names.
    public var registeredTypes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(configs.keys)
    }

    private init() {}

    // MARK: - Registration

    /// Register an entity type for sync.
    ///
    /// - Parameters:
    ///   - entityType: The entity type to register
    ///   - configure: Closure to configure the entity
    public func register<Entity: PolySyncable>(
        _: Entity.Type,
        configure: (PolyEntityConfig<Entity>) -> Void,
    ) {
        let config = PolyEntityConfig<Entity>()
        configure(config)

        guard !config.tableName.isEmpty else {
            polyError("PolyBaseRegistry: Cannot register \(Entity.self) without a table name")
            return
        }

        let key = String(describing: Entity.self)
        let anyConfig = AnyEntityConfig(config)

        lock.lock()
        configs[key] = anyConfig
        tableToType[config.tableName] = key
        lock.unlock()

        polyDebug("PolyBaseRegistry: Registered \(Entity.self) -> \(config.tableName) with \(config.fields.count) fields")
    }

    // MARK: - Lookup

    /// Get the configuration for an entity type.
    public func config<Entity: PolySyncable>(for _: Entity.Type) -> AnyEntityConfig? {
        let key = String(describing: Entity.self)
        lock.lock()
        defer { lock.unlock() }
        return configs[key]
    }

    /// Get the configuration for an entity instance.
    public func config(for entity: Any) -> AnyEntityConfig? {
        let key = String(describing: type(of: entity))
        lock.lock()
        defer { lock.unlock() }
        return configs[key]
    }

    /// Get the configuration for a table name.
    public func config(forTable tableName: String) -> AnyEntityConfig? {
        lock.lock()
        defer { lock.unlock() }
        guard let typeKey = tableToType[tableName] else { return nil }
        return configs[typeKey]
    }

    /// Get the configuration for a type name string.
    /// Used for lazy resolution of parent relationships.
    public func config(forTypeName typeName: String) -> AnyEntityConfig? {
        lock.lock()
        defer { lock.unlock() }
        return configs[typeName]
    }

    /// Check if an entity type is registered.
    public func isRegistered(_ entityType: (some PolySyncable).Type) -> Bool {
        config(for: entityType) != nil
    }

    /// Check if a table is registered.
    public func isRegistered(table: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tableToType[table] != nil
    }

    // MARK: - Clear (for testing)

    /// Clear all registrations. Useful for testing.
    public func clearAll() {
        lock.lock()
        configs.removeAll()
        tableToType.removeAll()
        lock.unlock()
    }
}
