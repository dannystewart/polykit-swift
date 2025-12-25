//
//  PolyFieldMapping.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Supabase

// MARK: - PolyFieldType

/// Supported field types for sync.
public enum PolyFieldType: Sendable {
    case string
    case int
    case double
    case bool
    case date
    case optionalString
    case optionalInt
    case optionalDouble
    case optionalDate
    case uuid
    case optionalUUID
}

// MARK: - PolyFieldMapping

/// Represents a mapping between a Swift property and a Supabase column.
///
/// Field mappings are type-erased to allow storing heterogeneous mappings
/// in the same collection. The actual type information is preserved in
/// the getter and setter closures.
public struct PolyFieldMapping<Entity: PolySyncable>: Sendable {
    /// The Supabase column name
    public let columnName: String

    /// The Swift property name (for debugging)
    public let propertyName: String

    /// Whether this field should be encrypted
    public let encrypted: Bool

    /// The field type
    public let fieldType: PolyFieldType

    /// Whether this field can be nil
    public let isOptional: Bool

    /// If true, reject incoming empty values and keep the existing local value.
    /// Prevents accidental data erasure during sync.
    public let rejectIfEmpty: Bool

    /// Closure to get the value from an entity as AnyJSON
    let getValue: @Sendable (Entity) -> AnyJSON

    /// Closure to set a value on an entity from AnyJSON
    /// Returns true if the value was set, false if conversion failed
    let setValue: @Sendable (Entity, AnyJSON) -> Bool

    /// Closure to get the raw value for encryption (strings only)
    let getStringValue: (@Sendable (Entity) -> String?)?

    /// Closure to set a decrypted string value
    let setStringValue: (@Sendable (Entity, String) -> Void)?
}

// MARK: - PolyFieldMapping Factory Methods

public extension PolyFieldMapping {
    // MARK: String Fields

    /// Map a String property to a column.
    ///
    /// - Parameters:
    ///   - keyPath: The property to map
    ///   - column: The Supabase column name
    ///   - encrypted: Whether this field should be encrypted
    ///   - rejectIfEmpty: If true, incoming empty strings are rejected (existing value kept)
    static func map(
        _ keyPath: WritableKeyPath<Entity, String> & Sendable,
        to column: String,
        encrypted: Bool = false,
        rejectIfEmpty: Bool = false,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: encrypted,
            fieldType: .string,
            isOptional: false,
            rejectIfEmpty: rejectIfEmpty,
            getValue: { entity in
                .string(entity[keyPath: keyPath])
            },
            setValue: { entity, json in
                guard let value = json.stringValue else { return false }
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = value
                return true
            },
            getStringValue: { entity in
                entity[keyPath: keyPath]
            },
            setStringValue: { entity, value in
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = value
            },
        )
    }

    /// Map an optional String property to a column.
    ///
    /// - Parameters:
    ///   - keyPath: The property to map
    ///   - column: The Supabase column name
    ///   - encrypted: Whether this field should be encrypted
    ///   - rejectIfEmpty: If true, incoming empty/null strings are rejected (existing value kept)
    static func map(
        _ keyPath: WritableKeyPath<Entity, String?> & Sendable,
        to column: String,
        encrypted: Bool = false,
        rejectIfEmpty: Bool = false,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: encrypted,
            fieldType: .optionalString,
            isOptional: true,
            rejectIfEmpty: rejectIfEmpty,
            getValue: { entity in
                if let value = entity[keyPath: keyPath] {
                    return .string(value)
                }
                return .null
            },
            setValue: { entity, json in
                var mutableEntity = entity
                if json == .null {
                    mutableEntity[keyPath: keyPath] = nil
                } else if let value = json.stringValue {
                    mutableEntity[keyPath: keyPath] = value
                } else {
                    return false
                }
                return true
            },
            getStringValue: { entity in
                entity[keyPath: keyPath]
            },
            setStringValue: { entity, value in
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = value
            },
        )
    }

    // MARK: Int Fields

    /// Map an Int property to a column.
    static func map(
        _ keyPath: WritableKeyPath<Entity, Int> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .int,
            isOptional: false,
            rejectIfEmpty: false,
            getValue: { entity in
                .integer(entity[keyPath: keyPath])
            },
            setValue: { entity, json in
                guard let value = json.integerValue else { return false }
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = value
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    /// Map an optional Int property to a column.
    static func map(
        _ keyPath: WritableKeyPath<Entity, Int?> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .optionalInt,
            isOptional: true,
            rejectIfEmpty: false,
            getValue: { entity in
                if let value = entity[keyPath: keyPath] {
                    return .integer(value)
                }
                return .null
            },
            setValue: { entity, json in
                var mutableEntity = entity
                if json == .null {
                    mutableEntity[keyPath: keyPath] = nil
                } else if let value = json.integerValue {
                    mutableEntity[keyPath: keyPath] = value
                } else {
                    return false
                }
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    // MARK: Double Fields

    /// Map a Double property to a column.
    static func map(
        _ keyPath: WritableKeyPath<Entity, Double> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .double,
            isOptional: false,
            rejectIfEmpty: false,
            getValue: { entity in
                .double(entity[keyPath: keyPath])
            },
            setValue: { entity, json in
                guard let value = json.numericDoubleValue else { return false }
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = value
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    /// Map an optional Double property to a column.
    static func map(
        _ keyPath: WritableKeyPath<Entity, Double?> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .optionalDouble,
            isOptional: true,
            rejectIfEmpty: false,
            getValue: { entity in
                if let value = entity[keyPath: keyPath] {
                    return .double(value)
                }
                return .null
            },
            setValue: { entity, json in
                var mutableEntity = entity
                if json == .null {
                    mutableEntity[keyPath: keyPath] = nil
                } else if let value = json.numericDoubleValue {
                    mutableEntity[keyPath: keyPath] = value
                } else {
                    return false
                }
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    // MARK: Bool Fields

    /// Map a Bool property to a column.
    static func map(
        _ keyPath: WritableKeyPath<Entity, Bool> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .bool,
            isOptional: false,
            rejectIfEmpty: false,
            getValue: { entity in
                .bool(entity[keyPath: keyPath])
            },
            setValue: { entity, json in
                guard let value = json.boolValue else { return false }
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = value
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    // MARK: Date Fields

    /// Map a Date property to a column (stored as ISO8601 string).
    ///
    /// Uses `PolyISO8601` for robust parsing that handles multiple Supabase date formats:
    /// - With fractional seconds: `2024-12-22T10:00:00.123456Z`
    /// - Without fractional seconds: `2024-12-22T10:00:00Z`
    /// - With space instead of T: `2024-12-22 10:00:00Z`
    static func map(
        _ keyPath: WritableKeyPath<Entity, Date> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .date,
            isOptional: false,
            rejectIfEmpty: false,
            getValue: { entity in
                .string(PolyISO8601.format(entity[keyPath: keyPath]))
            },
            setValue: { entity, json in
                guard
                    let string = json.stringValue,
                    let date = PolyISO8601.parse(string) else { return false }
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = date
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    /// Map an optional Date property to a column (stored as ISO8601 string).
    ///
    /// Uses `PolyISO8601` for robust parsing that handles multiple Supabase date formats:
    /// - With fractional seconds: `2024-12-22T10:00:00.123456Z`
    /// - Without fractional seconds: `2024-12-22T10:00:00Z`
    /// - With space instead of T: `2024-12-22 10:00:00Z`
    static func map(
        _ keyPath: WritableKeyPath<Entity, Date?> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .optionalDate,
            isOptional: true,
            rejectIfEmpty: false,
            getValue: { entity in
                if let date = entity[keyPath: keyPath] {
                    return .string(PolyISO8601.format(date))
                }
                return .null
            },
            setValue: { entity, json in
                var mutableEntity = entity
                if json == .null {
                    mutableEntity[keyPath: keyPath] = nil
                } else if
                    let string = json.stringValue,
                    let date = PolyISO8601.parse(string)
                {
                    mutableEntity[keyPath: keyPath] = date
                } else {
                    return false
                }
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    // MARK: UUID Fields

    /// Map a UUID property to a column (stored as string).
    static func map(
        _ keyPath: WritableKeyPath<Entity, UUID> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .uuid,
            isOptional: false,
            rejectIfEmpty: false,
            getValue: { entity in
                .string(entity[keyPath: keyPath].uuidString)
            },
            setValue: { entity, json in
                guard
                    let string = json.stringValue,
                    let uuid = UUID(uuidString: string) else { return false }
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = uuid
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    /// Map an optional UUID property to a column (stored as string).
    static func map(
        _ keyPath: WritableKeyPath<Entity, UUID?> & Sendable,
        to column: String,
    ) -> PolyFieldMapping {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .optionalUUID,
            isOptional: true,
            rejectIfEmpty: false,
            getValue: { entity in
                if let uuid = entity[keyPath: keyPath] {
                    return .string(uuid.uuidString)
                }
                return .null
            },
            setValue: { entity, json in
                var mutableEntity = entity
                if json == .null {
                    mutableEntity[keyPath: keyPath] = nil
                } else if
                    let string = json.stringValue,
                    let uuid = UUID(uuidString: string)
                {
                    mutableEntity[keyPath: keyPath] = uuid
                } else {
                    return false
                }
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    // MARK: RawRepresentable Fields (Enums with String raw values)

    /// Map a RawRepresentable property (e.g., enum) to a column.
    /// The raw value is stored as a string.
    static func mapRaw<R: RawRepresentable & Sendable>(
        _ keyPath: WritableKeyPath<Entity, R> & Sendable,
        to column: String,
    ) -> PolyFieldMapping where R.RawValue == String {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .string,
            isOptional: false,
            rejectIfEmpty: false,
            getValue: { entity in
                .string(entity[keyPath: keyPath].rawValue)
            },
            setValue: { entity, json in
                guard
                    let string = json.stringValue,
                    let value = R(rawValue: string) else { return false }
                var mutableEntity = entity
                mutableEntity[keyPath: keyPath] = value
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }

    /// Map an optional RawRepresentable property (e.g., enum) to a column.
    /// The raw value is stored as a string, or null if nil.
    static func mapRaw<R: RawRepresentable & Sendable>(
        _ keyPath: WritableKeyPath<Entity, R?> & Sendable,
        to column: String,
    ) -> PolyFieldMapping where R.RawValue == String {
        PolyFieldMapping(
            columnName: column,
            propertyName: String(describing: keyPath),
            encrypted: false,
            fieldType: .optionalString,
            isOptional: true,
            rejectIfEmpty: false,
            getValue: { entity in
                if let value = entity[keyPath: keyPath] {
                    return .string(value.rawValue)
                }
                return .null
            },
            setValue: { entity, json in
                var mutableEntity = entity
                if json == .null {
                    mutableEntity[keyPath: keyPath] = nil
                } else if
                    let string = json.stringValue,
                    let value = R(rawValue: string)
                {
                    mutableEntity[keyPath: keyPath] = value
                } else {
                    return false
                }
                return true
            },
            getStringValue: nil,
            setStringValue: nil,
        )
    }
}

// MARK: - AnyFieldMapping

/// Type-erased field mapping for storage in collections.
///
/// This allows storing field mappings for different entity types
/// in the same dictionary.
public struct AnyFieldMapping: Sendable {
    public let columnName: String
    public let propertyName: String
    public let encrypted: Bool
    public let fieldType: PolyFieldType
    public let isOptional: Bool

    /// If true, reject incoming empty values and keep the existing local value.
    public let rejectIfEmpty: Bool

    private let _getValue: @Sendable (Any) -> AnyJSON?
    private let _setValue: @Sendable (Any, AnyJSON) -> Bool
    private let _getStringValue: (@Sendable (Any) -> String?)?
    private let _setStringValue: (@Sendable (Any, String) -> Void)?

    public init<Entity: PolySyncable>(_ mapping: PolyFieldMapping<Entity>) {
        self.columnName = mapping.columnName
        self.propertyName = mapping.propertyName
        self.encrypted = mapping.encrypted
        self.fieldType = mapping.fieldType
        self.isOptional = mapping.isOptional
        self.rejectIfEmpty = mapping.rejectIfEmpty

        self._getValue = { entity in
            guard let typedEntity = entity as? Entity else { return nil }
            return mapping.getValue(typedEntity)
        }

        self._setValue = { entity, json in
            guard let typedEntity = entity as? Entity else { return false }
            return mapping.setValue(typedEntity, json)
        }

        if let getStr = mapping.getStringValue {
            self._getStringValue = { entity in
                guard let typedEntity = entity as? Entity else { return nil }
                return getStr(typedEntity)
            }
        } else {
            self._getStringValue = nil
        }

        if let setStr = mapping.setStringValue {
            self._setStringValue = { entity, value in
                guard let typedEntity = entity as? Entity else { return }
                setStr(typedEntity, value)
            }
        } else {
            self._setStringValue = nil
        }
    }

    /// Get the value from an entity.
    public func getValue(from entity: Any) -> AnyJSON? {
        self._getValue(entity)
    }

    /// Set a value on an entity.
    public func setValue(on entity: Any, value: AnyJSON) -> Bool {
        self._setValue(entity, value)
    }

    /// Get the string value for encryption.
    public func getStringValue(from entity: Any) -> String? {
        self._getStringValue?(entity)
    }

    /// Set a decrypted string value.
    public func setStringValue(on entity: Any, value: String) {
        self._setStringValue?(entity, value)
    }
}
