//
//  PolyBaseStorage.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation
import Storage
import Supabase

// MARK: - PolyBaseStorage

/// Service for uploading and downloading files to/from Supabase Storage.
///
/// Usage:
/// ```swift
/// let storage = PolyBaseStorage(bucketName: "attachments")
///
/// // Upload
/// let path = try await storage.upload(
///     data: imageData,
///     path: "user123/photo.jpg",
///     mimeType: "image/jpeg"
/// )
///
/// // Download
/// let data = try await storage.download(path: path)
///
/// // Delete
/// try await storage.delete(path: path)
/// ```
public final class PolyBaseStorage: Sendable {
    /// The bucket name this storage instance operates on.
    public let bucketName: String

    /// Create a storage service for a specific bucket.
    ///
    /// - Parameter bucketName: The Supabase Storage bucket name.
    public init(bucketName: String) {
        self.bucketName = bucketName
    }

    // MARK: - Helpers

    /// Get the extension for a MIME type.
    public static func extensionFromMimeType(_ mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "text/plain": return "txt"
        case "text/markdown": return "md"
        case "application/json": return "json"
        case "application/pdf": return "pdf"
        default:
            // Extract from mime type (e.g., "text/swift" -> "swift")
            if let subtype = mimeType.split(separator: "/").last {
                return String(subtype)
            }
            return "bin"
        }
    }

    // MARK: - Upload

    /// Upload data to Supabase Storage.
    ///
    /// - Parameters:
    ///   - data: The file data to upload.
    ///   - path: The storage path (e.g., "user-id/folder/file.ext").
    ///   - mimeType: The MIME type of the file.
    ///   - upsert: Whether to overwrite existing files. Defaults to `true`.
    /// - Returns: The storage path on success.
    @discardableResult
    public func upload(
        data: Data,
        path: String,
        mimeType: String,
        upsert: Bool = true,
    ) async throws -> String {
        let client = try PolyBaseClient.requireClient()

        try await client.storage
            .from(self.bucketName)
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: mimeType, upsert: upsert),
            )

        polyDebug("PolyBase: Uploaded \(data.count) bytes to \(path)")
        return path
    }

    /// Upload data with automatic path generation.
    ///
    /// - Parameters:
    ///   - data: The file data to upload.
    ///   - userID: The user's ID (used as path prefix).
    ///   - folder: Optional subfolder within the user's storage.
    ///   - filename: The filename to use.
    ///   - mimeType: The MIME type of the file.
    /// - Returns: The full storage path.
    @discardableResult
    public func upload(
        data: Data,
        userID: UUID,
        folder: String? = nil,
        filename: String,
        mimeType: String,
    ) async throws -> String {
        var pathComponents = [userID.uuidString]
        if let folder, !folder.isEmpty {
            pathComponents.append(folder)
        }
        pathComponents.append(filename)
        let path = pathComponents.joined(separator: "/")

        return try await self.upload(data: data, path: path, mimeType: mimeType)
    }

    // MARK: - Download

    /// Download data from Supabase Storage.
    ///
    /// - Parameter path: The storage path to download.
    /// - Returns: The file data.
    public func download(path: String) async throws -> Data {
        let client = try PolyBaseClient.requireClient()

        let data = try await client.storage
            .from(self.bucketName)
            .download(path: path)

        polyDebug("PolyBase: Downloaded \(data.count) bytes from \(path)")
        return data
    }

    // MARK: - Delete

    /// Delete a file from Supabase Storage.
    ///
    /// - Parameter path: The storage path to delete.
    public func delete(path: String) async throws {
        let client = try PolyBaseClient.requireClient()

        _ = try await client.storage
            .from(self.bucketName)
            .remove(paths: [path])

        polyDebug("PolyBase: Deleted \(path)")
    }

    /// Delete multiple files from Supabase Storage.
    ///
    /// - Parameter paths: The storage paths to delete.
    public func delete(paths: [String]) async throws {
        guard !paths.isEmpty else { return }

        let client = try PolyBaseClient.requireClient()

        _ = try await client.storage
            .from(self.bucketName)
            .remove(paths: paths)

        polyDebug("PolyBase: Deleted \(paths.count) files")
    }

    /// Delete all files in a folder.
    ///
    /// - Parameter folderPath: The folder path (e.g., "user-id/subfolder").
    public func deleteFolder(path folderPath: String) async throws {
        let client = try PolyBaseClient.requireClient()

        // List all files in the folder
        let files = try await client.storage
            .from(self.bucketName)
            .list(path: folderPath)

        guard !files.isEmpty else { return }

        // Build full paths and delete
        let paths = files.map { folderPath + "/" + $0.name }
        _ = try await client.storage
            .from(self.bucketName)
            .remove(paths: paths)

        polyDebug("PolyBase: Deleted \(paths.count) files from folder \(folderPath)")
    }

    // MARK: - List

    /// List files in a folder.
    ///
    /// - Parameter folderPath: The folder path to list.
    /// - Returns: Array of file objects.
    public func list(path folderPath: String) async throws -> [FileObject] {
        let client = try PolyBaseClient.requireClient()

        return try await client.storage
            .from(self.bucketName)
            .list(path: folderPath)
    }
}
