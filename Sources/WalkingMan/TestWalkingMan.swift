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
            loadingText: "Swift Walking Man is walking...",
            color: .cyan,
            speed: 0.15,  // Same as Python version
            width: 20
        )

        // Start the animation
        walkingMan.start()

        // Let him walk for a few seconds
        Thread.sleep(forTimeInterval: 5.0)

        // Stop the animation
        walkingMan.stop()
    }
}

@main
struct TestApp {
    static func main() {
        TestWalkingMan.run()
    }
}
