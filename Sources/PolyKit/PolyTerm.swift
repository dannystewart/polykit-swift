//
//  PolyTerm.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif os(Windows)
    import CRT
    import WinSDK
#endif

// MARK: - PolyTerm

public enum PolyTerm {
    /// Returns a string with the specified color and style attributes.
    ///
    /// - Parameters:
    ///   - text:  The text to colorize.
    ///   - color: The name of the color from the ANSIColor enum.
    /// - Returns: A colorized string.
    public static func color(_ text: String, _ color: ANSIColor) -> String {
        "\(color.rawValue)\(text)\(ANSIColor.reset.rawValue)"
    }

    /// Prints a colorized string to the console.
    ///
    /// - Parameters:
    ///   - text:       The text to colorize.
    ///   - color:      The name of the color from the ANSIColor enum.
    ///   - terminator: The string to print after the text. Defaults to "\n".
    public static func printColor(_ text: String, _ color: ANSIColor, terminator: String = "\n") {
        print(PolyTerm.color(text, color), terminator: terminator)
    }

    /// Determines if the terminal supports ANSI colors based on the environment.
    ///
    /// - Returns: True if we're in a real terminal that supports colors, false if in Xcode or other non-color environment.
    public static func supportsANSI() -> Bool {
        #if os(iOS)
            return false
        #endif

        // Check if we're running in Xcode by looking for Xcode-specific environment variables
        if
            ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil ||
            ProcessInfo.processInfo.environment["XCODE_VERSION_MAJOR"] != nil { return false }

        // Check if stdout is a TTY and we have a TERM environment variable
        #if os(Windows)
            return _isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != nil
        #else
            return isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != nil
        #endif
    }

    /// Uses the terminal's raw mode to read a single character without waiting for Enter.
    public static func readSingleChar() -> String {
        #if os(Windows)
            return readSingleCharWindows()
        #else
            return readSingleCharPOSIX()
        #endif
    }

    #if os(Windows)
        /// Windows-specific implementation using Console API
        private static func readSingleCharWindows() -> String {
            // Ensure output is flushed before reading input
            // Flush all output streams without referencing the global `stdout`,
            // which Swift 6 considers non-concurrency-safe on some platforms.
            fflush(nil)

            let hStdin = GetStdHandle(STD_INPUT_HANDLE)
            if hStdin == INVALID_HANDLE_VALUE {
                return ""
            }

            // Get current console mode
            var originalMode: DWORD = 0
            if !GetConsoleMode(hStdin, &originalMode) {
                return ""
            }

            // Disable line input and echo
            let rawMode = originalMode & ~DWORD(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)
            if !SetConsoleMode(hStdin, rawMode) {
                return ""
            }

            defer {
                // Restore original console mode
                SetConsoleMode(hStdin, originalMode)
            }

            // Read a single character
            var byte: UInt8 = 0
            var bytesRead: DWORD = 0
            if ReadFile(hStdin, &byte, 1, &bytesRead, nil), bytesRead == 1 {
                if let unicodeScalar = UnicodeScalar(Int(byte)) {
                    return String(Character(unicodeScalar))
                }
            }
            return ""
        }
    #endif

    #if !os(Windows)
        /// POSIX implementation using termios (Unix/Linux/macOS)
        private static func readSingleCharPOSIX() -> String {
            // Ensure output is flushed before reading input
            // Flush all output streams without referencing the global `stdout`,
            // which Swift 6 considers non-concurrency-safe on some platforms.
            fflush(nil)

            // Prefer reading directly from the controlling TTY to avoid redirected stdin issues
            var fd: Int32 = STDIN_FILENO
            var openedTtyFd: Int32 = -1
            if isatty(STDIN_FILENO) == 0 {
                #if !os(Windows)
                    openedTtyFd = open("/dev/tty", O_RDONLY)
                    if openedTtyFd != -1 {
                        fd = openedTtyFd
                    }
                #endif
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
    #endif
}
