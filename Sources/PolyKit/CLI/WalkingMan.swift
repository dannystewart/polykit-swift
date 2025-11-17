//
//  WalkingMan.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

/// The cute and entertaining Walking Man <('-'<) animation for tasks that take time.
///
/// Walking Man is the unsung hero who brings a bit of joy to operations that would otherwise be
/// frustrating or tedious. He's a simple character, but he's always there when you need him.
public class WalkingMan: @unchecked Sendable {
    // MARK: Static Properties

    // The ASCII, the myth, the legend: it's SWIFT Walking Man!
    static let characterLeft = "<('-'<) "
    static let characterMiddle = "<('-')>"
    static let characterRight = " (>'-')>"

    // MARK: Properties

    // Swift Walking Man properties
    let loadingText: String?
    let color: ANSIColor?
    let speed: Double
    let width: Int

    // Animation state
    private var position: Int = 0
    private var direction: Int = 1 // 1 for right, -1 for left
    private var turnState: Int = 0 // 0 = normal, 1 = showing middle, 2 = completed turn
    private var isRunning: Bool = false

    // MARK: Lifecycle

    public init(
        loadingText: String? = nil,
        color: ANSIColor? = .cyan,
        speed: Double = 0.15,
        width: Int = 25,
    ) {
        self.loadingText = loadingText
        self.color = color
        self.speed = speed
        self.width = width
    }

    // MARK: Functions

    public func start() {
        // Reset animation state to ensure clean start
        position = 0
        direction = 1
        turnState = 0
        isRunning = true

        // Hide cursor during animation
        print("\u{001B}[?25l", terminator: "")

        // Show loading text if provided
        if let text = loadingText {
            if let color {
                PolyTerm.printColor(text, color)
            } else {
                print(text)
            }
        }

        // Start the animation loop
        animate()
    }

    public func stop() {
        isRunning = false

        // Show cursor again
        print("\u{001B}[?25h", terminator: "")
    }

    private func animate() {
        while isRunning {
            // Print the current frame
            printFrame()

            // Update position and direction
            updatePosition()

            // Wait for the next frame
            Thread.sleep(forTimeInterval: speed)
        }
    }

    private func printFrame() {
        let character = getCurrentCharacter()
        let coloredCharacter = color != nil ? PolyTerm.color(character, color!) : character
        let spaces = String(repeating: " ", count: position)

        // Clear the entire line and print Walking Man
        print("\r\u{001B}[K\(spaces)\(coloredCharacter)", terminator: "")
        // Flush all output streams to ensure the frame is visible immediately.
        // Using `nil` avoids directly touching the global `stdout`, which is
        // treated as non-concurrency-safe by Swift 6 on some platforms.
        fflush(nil)
    }

    private func getCurrentCharacter() -> String {
        switch turnState {
        case 1: Self.characterMiddle
        default: direction == 1 ? Self.characterRight : Self.characterLeft
        }
    }

    private func updatePosition() {
        // Handle turn state transitions
        if turnState == 1 {
            // Middle position shown, now complete turn and resume movement
            turnState = 0
            direction = -direction // Reverse direction
            position += direction // First step in new direction

        } else {
            // Check boundaries BEFORE moving
            if position + direction >= width, direction == 1 {
                // About to hit right boundary - stay at boundary and start turn
                position = width - 1 // Stay within bounds
                turnState = 1
                // Don't change direction yet - that happens in turnState 1

            } else if position + direction < 0, direction == -1 {
                // About to hit left boundary - stay at boundary and start turn
                position = 0
                turnState = 1
                // Don't change direction yet - that happens in turnState 1

            } else {
                // Normal movement
                position += direction
            }
        }
    }
}
