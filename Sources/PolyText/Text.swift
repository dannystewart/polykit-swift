//
//  PolyText.swift
//  polykit-swift
//
//  Created by Danny Stewart on 9/26/25.
//

public struct Text {
    /// Returns a string with the specified color and style attributes.
    ///
    /// - Parameters:
    ///   - text:  The text to colorize.
    ///   - color: The name of the color from TextColor enum.
    /// - Returns: A colorized string.
    public static func color(_ text: String, _ color: TextColor) -> String {
        return "\(color.rawValue)\(text)\(TextColor.reset.rawValue)"
    }

    /// Prints a colorized string to the console.
    ///
    /// - Parameters:
    ///   - text:       The text to colorize.
    ///   - color:      The name of the color from TextColor enum.
    ///   - terminator: The string to print after the text.
    public static func printColor(_ text: String, _ color: TextColor, terminator: String = "\n") {
        print(Text.color(text, color), terminator: terminator)
    }

    /// Returns a pluralized string based on the count.
    ///
    /// - Parameters:
    ///   - word:    The word to pluralize.
    ///   - count:   The number of items.
    ///   - showNum: Whether to show the number.
    ///   - commas:  Whether to use commas.
    /// - Returns: A pluralized string.
    public static func plural(_ word: String, count: Int, showNum: Bool = true, commas: Bool = true)
        -> String
    {
        if count == 1 {
            return showNum ? "1 \(word)" : word
        }

        let formattedCount = commas ? "\(count)" : "\(count)"
        let pluralized = word.hasSuffix("s") ? "\(word)es" : "\(word)s"

        return showNum ? "\(formattedCount) \(pluralized)" : pluralized
    }
}
