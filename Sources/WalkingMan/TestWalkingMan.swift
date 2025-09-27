//
//  TestWalkingMan.swift
//  polykit-swift
//
//  Created by Danny Stewart on 9/26/25.
//

import Foundation
import PolyText

struct TestWalkingMan {
    static func run() {
        var walkingMan = WalkingMan(
            color: .cyan,
            speed: 0.15,
            width: 45
        )

        Text.printColor("It's Swift Walking Man! Press any key to say goodbye.", .green)

        // Start the animation in a background thread
        DispatchQueue.global().async { [walkingMan] in
            var man = walkingMan
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
        Text.printColor("\n\nWalking Man says goodbye! 👋", .green)
        walkingMan.stop()
    }
}

@main
struct TestApp {
    static func main() {
        TestWalkingMan.run()
    }
}
