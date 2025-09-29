import Foundation

public enum Text {
    /// Returns a string with the specified color and style attributes.
    ///
    /// - Parameters:
    ///   - text:  The text to colorize.
    ///   - color: The name of the color from TextColor enum.
    /// - Returns: A colorized string.
    public static func color(_ text: String, _ color: TextColor) -> String {
        "\(color.rawValue)\(text)\(TextColor.reset.rawValue)"
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
}
