//
//  PolyText.swift
//  polykit-swift
//
//  Created by Danny Stewart on 9/26/25.
//

import Foundation

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
    ///   - terminator: The string to print after the text. Defaults to "\n".
    public static func printColor(_ text: String, _ color: TextColor, terminator: String = "\n") {
        print(Text.color(text, color), terminator: terminator)
    }

    /// Returns a pluralized string based on the count.
    ///
    /// - Parameters:
    ///   - word:       The word to pluralize.
    ///   - count:      The number of items.
    ///   - showNumber: Include the number with the word. Defaults to true.
    ///   - useCommas:  Add thousands separators to numbers. Defaults to true.
    /// - Returns: A pluralized string.
    public static func plural(
        _ word: String,
        count: Int,
        showNumber: Bool = true,
        useCommas: Bool = true
    )
        -> String
    {
        if count == 1 {
            return showNumber ? "1 \(word)" : word
        }

        let formattedCount = useCommas ? formatNumberWithCommas(count) : "\(count)"
        let pluralized = word.hasSuffix("s") ? "\(word)es" : "\(word)s"

        return showNumber ? "\(formattedCount) \(pluralized)" : pluralized
    }

    /// Format a number with various options for text representation.
    ///
    /// - Parameters:
    ///   - number:     The number to format.
    ///   - word:       Optional word to append (will be pluralized if needed).
    ///   - showNumber: Include the number with the word. Defaults to true.
    ///   - useCommas:  Add thousands separators to numbers. Defaults to true.
    /// - Returns: The formatted string.
    public static func formatNumber(
        _ number: Int,
        word: String? = nil,
        showNumber: Bool = true,
        useCommas: Bool = true
    ) -> String {
        // Format the number with or without commas
        let numStr = useCommas ? formatNumberWithCommas(number) : "\(number)"

        if let word = word {
            // Handle word if provided
            let pluralized = plural(word, count: number, showNumber: false, useCommas: useCommas)
            return showNumber ? "\(numStr) \(pluralized)" : pluralized
        } else {
            return numStr
        }
    }

    /// Format a number with commas.
    ///
    /// - Parameter number: The number to format.
    /// - Returns: The formatted string.
    public static func formatNumberWithCommas(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3

        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}
