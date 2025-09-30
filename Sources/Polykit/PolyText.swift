import Foundation

// MARK: - Text

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

// MARK: - TextColor

/// Enum representing various text colors.
public enum TextColor: String, CaseIterable, Sendable {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case white = "\u{001B}[37m"
    case black = "\u{001B}[30m"
    case blue = "\u{001B}[34m"
    case cyan = "\u{001B}[36m"
    case gray = "\u{001B}[90m"
    case green = "\u{001B}[32m"
    case magenta = "\u{001B}[95m"
    case purple = "\u{001B}[35m"
    case red = "\u{001B}[31m"
    case yellow = "\u{001B}[33m"
    case brightBlue = "\u{001B}[94m"
    case brightCyan = "\u{001B}[96m"
    case brightGreen = "\u{001B}[92m"
    case brightRed = "\u{001B}[91m"
    case brightWhite = "\u{001B}[97m"
    case brightYellow = "\u{001B}[93m"
}
