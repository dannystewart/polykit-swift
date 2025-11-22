//
//  AnimatedEqualizer.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import SwiftUI

/// A beautiful animated equalizer visualization that responds to audio playback.
///
/// Displays animated frequency bars that move in response to music, similar to
/// the Dynamic Island music visualization. Can operate in simulated mode (using
/// realistic random movement) or real mode (when connected to actual FFT analysis).
public struct AnimatedEqualizer: View {
    // MARK: SwiftUI Properties

    // MARK: - Private State

    @State private var barHeights: [CGFloat] = []
    @State private var animationTask: Task<Void, Never>?

    // MARK: Properties

    /// Whether the equalizer should be animating (tied to playback state)
    public let isPlaying: Bool

    /// Number of frequency bars to display
    public let barCount: Int

    /// Optional real frequency data (0.0 to 1.0 per band)
    /// If nil, uses simulated visualization
    public let frequencyData: [Float]?

    /// Bar color
    public let barColor: Color

    /// Spacing between bars
    public let spacing: CGFloat

    /// Minimum bar height as fraction of container (0.0 to 1.0)
    public let minimumBarHeight: CGFloat

    /// Whether to use enhanced dramatic variation (default: true)
    public let dramaticMode: Bool

    // MARK: Lifecycle

    /// Create an animated equalizer.
    ///
    /// - Parameters:
    ///   - isPlaying: Whether audio is currently playing
    ///   - barCount: Number of frequency bars (default: 5)
    ///   - frequencyData: Optional real FFT data, if available
    ///   - barColor: Color for the bars (default: accent color)
    ///   - spacing: Space between bars (default: 3)
    ///   - minimumBarHeight: Minimum bar height fraction (default: 0.05)
    ///   - dramaticMode: Use enhanced dramatic variation (default: true)
    public init(
        isPlaying: Bool,
        barCount: Int = 5,
        frequencyData: [Float]? = nil,
        barColor: Color = .accentColor,
        spacing: CGFloat = 3,
        minimumBarHeight: CGFloat = 0.05,
        dramaticMode: Bool = true,
    ) {
        self.isPlaying = isPlaying
        self.barCount = barCount
        self.frequencyData = frequencyData
        self.barColor = barColor
        self.spacing = spacing
        self.minimumBarHeight = minimumBarHeight
        self.dramaticMode = dramaticMode
    }

    // MARK: Content Properties

    // MARK: View

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: spacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor)
                        .frame(
                            width: barWidth(containerWidth: geometry.size.width),
                            height: barHeight(
                                for: index,
                                containerHeight: geometry.size.height,
                            ),
                        )
                        .frame(maxHeight: .infinity, alignment: .center)
                        .animation(
                            .smooth(duration: animationDuration(for: index)),
                            value: barHeights.count > index ? barHeights[index] : 0,
                        )
                }
            }
        }
        .onAppear {
            initializeBarHeights()
            if isPlaying {
                startAnimation()
            }
        }
        .onChange(of: isPlaying) { _, newValue in
            if newValue {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
        .onChange(of: frequencyData) { _, newData in
            if let data = newData, data.count >= barCount {
                updateFromFrequencyData(data)
            }
        }
        .onDisappear {
            stopAnimation()
        }
    }

    // MARK: Functions

    // MARK: - Private Methods

    private func initializeBarHeights() {
        barHeights = Array(repeating: minimumBarHeight, count: barCount)
    }

    private func barWidth(containerWidth: CGFloat) -> CGFloat {
        // Calculate available width after spacing
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let availableWidth = containerWidth - totalSpacing

        // Make bars very thin - use about 35% of available space per bar
        let barWidth = (availableWidth / CGFloat(barCount)) * 0.35
        return max(barWidth, 1.5) // Minimum 1.5pt width for visibility
    }

    private func barHeight(for index: Int, containerHeight: CGFloat) -> CGFloat {
        guard index < barHeights.count else { return containerHeight * minimumBarHeight }

        let targetHeight = barHeights[index]
        return containerHeight * max(minimumBarHeight, targetHeight)
    }

    private func animationDuration(for index: Int) -> Double {
        // Ultra-fast animation like Dynamic Island - almost instant
        let baseDuration = 0.05
        let variation = Double(index) * 0.005
        return baseDuration + variation
    }

    private func startAnimation() {
        // Cancel existing animation
        animationTask?.cancel()

        animationTask = Task {
            while !Task.isCancelled {
                await animateNextFrame()

                // Update frequency: 60 FPS for lightning-fast animation like Dynamic Island
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopAnimation() {
        animationTask?.cancel()
        animationTask = nil

        // Smoothly return to minimum height
        withAnimation(.smooth(duration: 0.3)) {
            for i in 0 ..< barCount {
                if i < barHeights.count {
                    barHeights[i] = minimumBarHeight
                }
            }
        }
    }

    @MainActor
    private func animateNextFrame() async {
        // If we have real frequency data, use it
        if let data = frequencyData, data.count >= barCount {
            updateFromFrequencyData(data)
            return
        }

        // SIMULATION DISABLED FOR DEBUGGING
        // If no real data, just show minimum height bars (flat)
        for i in 0 ..< barCount {
            guard i < barHeights.count else { continue }
            barHeights[i] = minimumBarHeight
        }

        // // Otherwise, use simulated realistic animation
        // for i in 0 ..< barCount {
        //     guard i < barHeights.count else { continue }
        //
        //     // Create realistic "music-like" movement patterns with DRAMATIC variation
        //     let frequencyPosition = Float(i) / Float(barCount - 1)
        //
        //     // Minimal energy bias across frequencies
        //     let energyBias = 1.0 - (frequencyPosition * 0.1)
        //
        //     // Constant rapid variation - different pattern per bar for independence
        //     let randomness = Float.random(in: 0.0 ... 1.0)
        //
        //     // Use different randomness patterns for more varied movement
        //     // Some bars get squared (more spiky), some get cubed (very spiky), some linear
        //     let variationPattern = i % 3
        //     let processedRandomness: Float = switch variationPattern {
        //     case 0: randomness * randomness * randomness // Cubic - super spiky
        //     case 1: randomness * randomness // Squared - spiky
        //     default: randomness // Linear - more consistent
        //     }
        //
        //     // Apply different movement characteristics per frequency range
        //     // ULTRA-low base, FULL variation range for constant dramatic motion
        //     let targetHeight = if frequencyPosition < 0.3 {
        //         // Bass: constant dramatic motion
        //         CGFloat(energyBias * (0.01 + processedRandomness * 0.99))
        //     } else if frequencyPosition < 0.6 {
        //         // Mids: constant dramatic motion
        //         CGFloat(energyBias * (0.01 + processedRandomness * 0.99))
        //     } else {
        //         // Highs: constant dramatic motion
        //         CGFloat(energyBias * (0.005 + processedRandomness * 0.995))
        //     }
        //
        //     // Minimal smoothing - very responsive but not flickery
        //     let currentHeight = barHeights[i]
        //     let smoothingFactor: CGFloat = 0.2
        //     barHeights[i] = currentHeight * (1 - smoothingFactor) + targetHeight * smoothingFactor
        // }
    }

    private func updateFromFrequencyData(_ data: [Float]) {
        for i in 0 ..< min(barCount, data.count) {
            guard i < barHeights.count else { continue }

            // Convert frequency data (0-1) to bar height with high sensitivity
            let frequencyLevel = CGFloat(data[i])

            // Full dynamic range - use squared value for more dramatic peaks
            let enhanced = frequencyLevel * frequencyLevel // Square for more dramatic response
            let targetHeight = minimumBarHeight + (enhanced * (1.0 - minimumBarHeight))

            // Minimal smoothing for responsive but smooth appearance
            let currentHeight = barHeights[i]
            let smoothingFactor: CGFloat = 0.7
            barHeights[i] = currentHeight * (1 - smoothingFactor) + targetHeight * smoothingFactor
        }
    }
}

// MARK: - Preview

#Preview("Playing - 5 bars") {
    AnimatedEqualizer(isPlaying: true, barCount: 5)
        .frame(width: 50, height: 24)
}

#Preview("Paused - 5 bars") {
    AnimatedEqualizer(isPlaying: false, barCount: 5)
        .frame(width: 50, height: 24)
}

#Preview("Playing - 8 bars") {
    AnimatedEqualizer(isPlaying: true, barCount: 8)
        .frame(width: 80, height: 32)
        .padding()
}

#Preview("Playing - Custom Color") {
    AnimatedEqualizer(
        isPlaying: true,
        barCount: 6,
        barColor: .pink,
        spacing: 4,
    )
    .frame(width: 60, height: 28)
    .padding()
    .background(Color.black)
}
