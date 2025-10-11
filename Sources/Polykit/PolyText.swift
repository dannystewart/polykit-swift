import Darwin
import Foundation

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

    /// Determines if the terminal supports ANSI colors based on the environment.
    ///
    /// - Returns: True if we're in a real terminal that supports colors, false if in Xcode or other non-color environment.
    public static func supportsColor() -> Bool {
        #if os(iOS)
            return false
        #endif

        // Check if we're running in Xcode by looking for Xcode-specific environment variables
        if
            ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil ||
            ProcessInfo.processInfo.environment["XCODE_VERSION_MAJOR"] != nil { return false }

        // Check if stdout is a TTY and we have a TERM environment variable
        return isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != nil
    }
}

// MARK: - PolyTerm

public enum PolyTerm {
    /// Uses the terminal's raw mode to read a single character without waiting for Enter.
    public static func readSingleChar() -> String {
        // Ensure output is flushed before reading input
        fflush(stdout)

        // Prefer reading directly from the controlling TTY to avoid redirected stdin issues
        var fd: Int32 = STDIN_FILENO
        var openedTtyFd: Int32 = -1
        if isatty(STDIN_FILENO) == 0 {
            openedTtyFd = open("/dev/tty", O_RDONLY)
            if openedTtyFd != -1 {
                fd = openedTtyFd
            }
        }

        // Configure terminal to raw mode so a single byte will return immediately
        var originalTermios = termios()
        if tcgetattr(fd, &originalTermios) != 0 {
            if openedTtyFd != -1 {
                close(openedTtyFd)
            }
            return ""
        }
        var rawTermios = originalTermios
        // set ICANON off, ECHO off, VMIN=1, VTIME=0, etc.
        cfmakeraw(&rawTermios)
        if tcsetattr(fd, TCSANOW, &rawTermios) != 0 {
            if openedTtyFd != -1 {
                close(openedTtyFd)
            }
            return ""
        }

        defer {
            // Restore terminal settings and close any opened TTY
            _ = tcsetattr(fd, TCSANOW, &originalTermios)
            if openedTtyFd != -1 {
                close(openedTtyFd)
            }
        }

        // Blocking read of exactly one byte
        var byte: UInt8 = 0
        let bytesRead = read(fd, &byte, 1)
        if bytesRead == 1, let unicodeScalar = UnicodeScalar(Int(byte)) {
            return String(Character(unicodeScalar))
        }
        return ""
    }
}
