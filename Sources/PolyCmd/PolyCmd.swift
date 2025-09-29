import Foundation

public enum PolyCmd {
    /// Uses the terminal's raw mode to read a single character without waiting for Enter.
    public static func readSingleChar() -> String {
        var originalTermios = termios()
        var newTermios = originalTermios
        tcgetattr(STDIN_FILENO, &newTermios)
        newTermios.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
        tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

        defer { // Restore original terminal settings
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        }

        let char = getchar()
        return String(Character(UnicodeScalar(Int(char))!))
    }
}
