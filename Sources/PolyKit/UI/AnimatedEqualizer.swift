//
//  AnimatedEqualizer.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import SwiftUI

/// A tiny animated equalizer visualization for showing audio playback activity.
///
/// Displays animated frequency bars that respond to real audio FFT data.
/// Optimized for very small sizes (20px height) where dramatic motion matters.
public struct AnimatedEqualizer: View {
    // MARK: - Private State

    @State private var barHeights: [CGFloat] = []

    // MARK: - Public Properties

    /// Whether the equalizer should be animating (tied to playback state)
    public let isPlaying: Bool

    /// Number of frequency bars to display
    public let barCount: Int

    /// Real frequency data (0.0 to 1.0+ per band). Required for animation.
    public let frequencyData: [Float]?

    /// Bar color
    public let barColor: Color

    /// Spacing between bars
    public let spacing: CGFloat

    /// Minimum bar height as fraction of container (0.0 to 1.0)
    public let minimumBarHeight: CGFloat

    /// Create an animated equalizer.
    ///
    /// - Parameters:
    ///   - isPlaying: Whether audio is currently playing
    ///   - barCount: Number of frequency bars (default: 5)
    ///   - frequencyData: Real FFT data from AudioAnalyzer
    ///   - barColor: Color for the bars (default: accent color)
    ///   - spacing: Space between bars (default: 2)
    ///   - minimumBarHeight: Minimum bar height fraction (default: 0.1)
    public init(
        isPlaying: Bool,
        barCount: Int = 5,
        frequencyData: [Float]? = nil,
        barColor: Color = .accentColor,
        spacing: CGFloat = 2,
        minimumBarHeight: CGFloat = 0.1,
    ) {
        self.isPlaying = isPlaying
        self.barCount = barCount
        self.frequencyData = frequencyData
        self.barColor = barColor
        self.spacing = spacing
        self.minimumBarHeight = minimumBarHeight
    }

    // MARK: - View

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: spacing) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    Capsule()
                        .fill(barColor)
                        .frame(
                            width: barWidth(containerWidth: geometry.size.width),
                            height: barHeight(for: index, containerHeight: geometry.size.height),
                        )
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
        // View-level animation keeps motion fluid at display refresh rate,
        // instead of restarting a spring for every individual value change.
        .animation(
            .spring(response: 0.12, dampingFraction: 0.8, blendDuration: 0.02),
            value: barHeights,
        )
        .onAppear {
            initializeBarHeights()
        }
        .onChange(of: isPlaying) { _, newValue in
            if !newValue {
                resetToMinimum()
            }
        }
        .onChange(of: frequencyData) { _, newData in
            if isPlaying, let data = newData, data.count >= barCount {
                updateFromFrequencyData(data)
            } else if !isPlaying {
                resetToMinimum()
            }
        }
    }

    // MARK: - Private Methods

    private func initializeBarHeights() {
        barHeights = Array(repeating: minimumBarHeight, count: barCount)
    }

    private func barWidth(containerWidth: CGFloat) -> CGFloat {
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let availableWidth = containerWidth - totalSpacing
        let barWidth = (availableWidth / CGFloat(barCount)) * 0.4
        return max(barWidth, 1.5)
    }

    private func barHeight(for index: Int, containerHeight: CGFloat) -> CGFloat {
        guard index < barHeights.count else { return containerHeight * minimumBarHeight }
        return containerHeight * barHeights[index]
    }

    private func updateFromFrequencyData(_ data: [Float]) {
        guard !data.isEmpty, barCount > 0 else { return }

        let sourceCount = data.count

        for barIndex in 0 ..< barCount {
            guard barIndex < barHeights.count else { continue }

            // Map each visual bar across the *entire* frequency range so we
            // don't over-represent the lowest bands when `data.count > barCount`.
            let barPosition: CGFloat = if barCount == 1 {
                0
            } else {
                CGFloat(barIndex) / CGFloat(barCount - 1)
            }

            let sourcePosition = barPosition * CGFloat(sourceCount - 1)
            let lowerIndex = Int(sourcePosition.rounded(.down))
            let upperIndex = min(lowerIndex + 1, sourceCount - 1)
            let t = sourcePosition - CGFloat(lowerIndex)

            let lowerValue = data[lowerIndex]
            let upperValue = data[upperIndex]

            // Simple linear interpolation between the two nearest bands
            let interpolated = (1 - t) * CGFloat(lowerValue) + t * CGFloat(upperValue)

            // Clamp to 0-1 range and ensure minimum visibility
            let clampedMagnitude = max(0, min(1, interpolated))
            let targetHeight = max(minimumBarHeight, clampedMagnitude)

            // Let the view-level spring interpolate between heights smoothly.
            barHeights[barIndex] = targetHeight
        }
    }

    private func resetToMinimum() {
        withAnimation(.easeOut(duration: 0.2)) {
            for i in 0 ..< barCount {
                if i < barHeights.count {
                    barHeights[i] = minimumBarHeight
                }
            }
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
