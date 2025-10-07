import Foundation

/// Utility class for comparing files and content with colored diff output.
public enum PolyDiff {
    /// Result of a diff operation containing the changes found.
    public struct DiffResult {
        public let hasChanges: Bool
        public let changes: [String]
        public let additions: [String]
        public let deletions: [String]

        public init(hasChanges: Bool, changes: [String], additions: [String], deletions: [String]) {
            self.hasChanges = hasChanges
            self.changes = changes
            self.additions = additions
            self.deletions = deletions
        }
    }

    /// Compare two files and show the differences with colored output.
    ///
    /// - Parameters:
    ///   - oldPath: The original file to compare against.
    ///   - newPath: The new file to compare.
    /// - Returns: A DiffResult containing the changes found.
    public static func files(oldPath: String, newPath: String) -> DiffResult {
        do {
            let oldContent = try String(contentsOfFile: oldPath, encoding: .utf8)
            let newContent = try String(contentsOfFile: newPath, encoding: .utf8)
            return content(old: oldContent, new: newContent, filename: newPath)
        } catch {
            print("Error reading files: \(error)")
            return DiffResult(hasChanges: false, changes: [], additions: [], deletions: [])
        }
    }

    /// Compare two content strings and show the differences with colored output.
    ///
    /// - Parameters:
    ///   - old: The original content to compare against.
    ///   - new: The new content to compare.
    ///   - filename: Optional filename for context in output.
    /// - Returns: A DiffResult containing the changes found.
    public static func content(old: String, new: String, filename: String? = nil) -> DiffResult {
        let content = filename ?? "text"

        var changes = [String]()
        var additions = [String]()
        var deletions = [String]()

        let diff = unifiedDiff(
            old: old.components(separatedBy: .newlines),
            new: new.components(separatedBy: .newlines),
            fromFile: "current \(content)",
            toFile: "new \(content)",
        )

        if diff.isEmpty {
            if filename != nil {
                print("No changes detected in \(content).")
            }
            return DiffResult(hasChanges: false, changes: [], additions: [], deletions: [])
        }

        if filename != nil {
            print("Changes detected in \(content):")
        }

        for line in diff {
            changes.append(line)
            processDiffLine(line, additions: &additions, deletions: &deletions)
        }

        return DiffResult(hasChanges: true, changes: changes, additions: additions, deletions: deletions)
    }

    /// Process a single line of diff output with colored printing.
    private static func processDiffLine(_ line: String, additions: inout [String],
                                        deletions: inout [String])
    {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if line.hasPrefix("+") {
            let normalizedLine = normalizeDiffLine(line)
            Text.printColor("  \(normalizedLine)", .green)
            additions.append(normalizedLine)
        } else if line.hasPrefix("-") {
            let normalizedLine = normalizeDiffLine(line)
            Text.printColor("  \(normalizedLine)", .red)
            deletions.append(normalizedLine)
        } else {
            print("  \(trimmedLine)")
        }
    }

    /// Normalize a diff line by ensuring proper spacing after the diff marker.
    private static func normalizeDiffLine(_ line: String) -> String {
        if line.hasPrefix("+") || line.hasPrefix("-") {
            let prefix = String(line.prefix(1))
            let content = String(line.dropFirst())

            if content.hasPrefix(" ") {
                // Already has space, keep as is
                return prefix + " " + content.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // No space, add one
                return prefix + " " + content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create a unified diff between two arrays of lines.
    private static func unifiedDiff(old: [String], new: [String], fromFile _: String,
                                    toFile _: String) -> [String]
    {
        var result = [String]()
        let maxLines = max(old.count, new.count)

        for i in 0 ..< maxLines {
            let oldLine = i < old.count ? old[i] : ""
            let newLine = i < new.count ? new[i] : ""

            if oldLine != newLine {
                if !oldLine.isEmpty {
                    result.append("-\(oldLine)")
                }
                if !newLine.isEmpty {
                    result.append("+\(newLine)")
                }
            }
        }

        return result
    }
}
