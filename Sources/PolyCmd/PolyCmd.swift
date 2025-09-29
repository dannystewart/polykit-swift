import Darwin
import Foundation

public enum PolyCmd {
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
        cfmakeraw(&rawTermios) // sets ICANON off, ECHO off, VMIN=1, VTIME=0, etc.
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
