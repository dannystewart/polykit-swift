import Foundation
import PolyText

enum TestWalkingMan {
    static func run() {
        let walkingMan = WalkingMan(
            color: .cyan,
            speed: 0.15,
            width: 45
        )

        Text.printColor("It's Walking Man… but in Swift! Press any key to say goodbye.", .green)

        // Start the animation in a background thread
        DispatchQueue.global().async { [walkingMan] in
            let man = walkingMan
            man.start()
        }

        // Wait for any key press in the main thread
        // Set terminal to raw mode to detect any key immediately
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var rawTermios = originalTermios
        rawTermios.c_lflag &= ~UInt(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)

        // Wait for any key
        _ = getchar()

        // Restore terminal settings
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)

        // Stop the animation and exit
        Text.printColor("\n\nGoodbye! 👋", .green)
        walkingMan.stop()
    }
}

@main
struct TestApp {
    static func main() {
        TestWalkingMan.run()
    }
}
