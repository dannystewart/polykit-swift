//
//  AudioAnalyzer.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Accelerate
import AVFoundation
import Foundation
import Observation

/// Real-time audio frequency analyzer using FFT.
///
/// Captures audio samples from an AVAudioEngine, performs Fast Fourier Transform
/// analysis, and publishes frequency band levels for visualization (e.g., EQ displays).
///
/// The analyzer divides the frequency spectrum into configurable bands and
/// provides smoothed amplitude values suitable for real-time animation.
@MainActor
@Observable
public final class AudioAnalyzer {
    // MARK: Properties

    /// Current frequency band levels (0.0 to 1.0), smoothed for animation
    public private(set) var frequencyBands: [Float] = []

    /// Whether audio analysis is currently active
    public private(set) var isAnalyzing: Bool = false

    // MARK: - Private Properties

    private let engine: AVAudioEngine
    private let numberOfBands: Int
    private let smoothingFactor: Float

    // FFT setup - these are accessed from audio callback thread
    // Using nonisolated(unsafe) because vDSP operations are thread-safe
    // and these values are immutable after initialization
    private nonisolated(unsafe) let fftSetup: vDSP_DFT_Setup?
    private let fftSize: Int = 2048
    private let window: [Float]

    /// State updated on MainActor
    private var smoothedBands: [Float]

    // MARK: Lifecycle

    /// Initialize the audio analyzer.
    ///
    /// - Parameters:
    ///   - engine: The AVAudioEngine to analyze audio from
    ///   - numberOfBands: Number of frequency bands to divide spectrum into (default: 8)
    ///   - smoothingFactor: Amount of smoothing applied to band levels, 0.0-1.0 (default: 0.75)
    public init(
        engine: AVAudioEngine,
        numberOfBands: Int = 8,
        smoothingFactor: Float = 0.75,
    ) {
        self.engine = engine
        self.numberOfBands = numberOfBands
        self.smoothingFactor = smoothingFactor

        smoothedBands = [Float](repeating: 0, count: numberOfBands)
        frequencyBands = [Float](repeating: 0, count: numberOfBands)

        // Create Hann window for FFT
        var tempWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&tempWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = tempWindow

        // Setup FFT
        fftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(fftSize),
            .FORWARD,
        )
    }

    deinit {
        // Clean up FFT resources
        // Note: Audio tap removal should be handled by explicit stop() call before deallocation
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    // MARK: Functions

    // MARK: - Control

    /// Start analyzing audio from the engine's main mixer node.
    public func start() {
        guard !isAnalyzing else { return }

        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)

        mainMixer.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(fftSize),
            format: format,
        ) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        isAnalyzing = true
    }

    /// Stop analyzing audio and remove the audio tap.
    public func stop() {
        guard isAnalyzing else { return }

        engine.mainMixerNode.removeTap(onBus: 0)
        isAnalyzing = false

        // Reset to zero
        for i in 0 ..< numberOfBands {
            frequencyBands[i] = 0
            smoothedBands[i] = 0
        }
    }

    // MARK: - Private Processing

    private nonisolated func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard
            let channelData = buffer.floatChannelData,
            let setup = fftSetup else { return }

        let frameCount = Int(buffer.frameLength)
        let channel = channelData[0]

        // Copy and window the input data
        var windowedSamples = [Float](repeating: 0, count: fftSize)
        let samplesToProcess = min(frameCount, fftSize)

        // Copy samples
        for i in 0 ..< samplesToProcess {
            windowedSamples[i] = channel[i]
        }

        // Apply window
        vDSP_vmul(windowedSamples, 1, window, 1, &windowedSamples, 1, vDSP_Length(fftSize))

        // Prepare buffers
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)

        // Copy windowed samples to real buffer
        real = windowedSamples

        // Perform FFT
        vDSP_DFT_Execute(setup, real, imaginary, &real, &imaginary)

        // Calculate magnitudes
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        for i in 0 ..< fftSize / 2 {
            let realPart = real[i]
            let imagPart = imaginary[i]
            magnitudes[i] = sqrtf(realPart * realPart + imagPart * imagPart)
        }

        // Convert to frequency bands
        let bands = calculateFrequencyBands(from: magnitudes)

        // Update on main actor
        Task { @MainActor in
            self.updateFrequencyBands(bands)
        }
    }

    private nonisolated func calculateFrequencyBands(from magnitudes: [Float]) -> [Float] {
        var bands = [Float](repeating: 0, count: numberOfBands)

        // Use logarithmic distribution for more musical frequency representation
        let maxFrequencyIndex = magnitudes.count

        for band in 0 ..< numberOfBands {
            // Logarithmic band calculation (more emphasis on lower frequencies)
            let startIndex = Int(pow(Float(maxFrequencyIndex), Float(band) / Float(numberOfBands)))
            let endIndex = Int(pow(Float(maxFrequencyIndex), Float(band + 1) / Float(numberOfBands)))

            var sum: Float = 0
            var count = 0

            for i in startIndex ..< min(endIndex, maxFrequencyIndex) {
                sum += magnitudes[i]
                count += 1
            }

            if count > 0 {
                bands[band] = sum / Float(count)
            }
        }

        // Normalize to 0-1 range
        if let maxMagnitude = bands.max(), maxMagnitude > 0 {
            for i in 0 ..< numberOfBands {
                bands[i] = bands[i] / maxMagnitude
                // Apply some compression for better visualization
                bands[i] = powf(bands[i], 0.5) // Square root for compression
            }
        }

        return bands
    }

    private func updateFrequencyBands(_ newBands: [Float]) {
        // Apply smoothing for less jittery animation
        for i in 0 ..< numberOfBands {
            smoothedBands[i] = smoothedBands[i] * smoothingFactor + newBands[i] * (1.0 - smoothingFactor)
            frequencyBands[i] = smoothedBands[i]
        }
    }
}
