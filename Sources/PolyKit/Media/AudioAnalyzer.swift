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
///
/// Note: Audio processing happens on audio thread, frequency band access is thread-safe.
public final class AudioAnalyzer: @unchecked Sendable {
    // MARK: Properties

    /// Current frequency band levels (0.0 to 1.0), smoothed for animation
    public var frequencyBands: [Float] = []

    /// Current volume level (0.0 to 1.0), representing overall amplitude
    public var currentVolume: Float = 0

    // MARK: - Private Properties

    private let engine: AVAudioEngine
    private let numberOfBands: Int
    private let smoothingFactor: Float
    private var _isAnalyzing: Bool = false

    // FFT setup - these are accessed from audio callback thread
    // Using nonisolated(unsafe) because vDSP operations are thread-safe
    // and these values are immutable after initialization
    private nonisolated(unsafe) let fftSetup: vDSP_DFT_Setup?
    private let fftSize: Int = 2048
    private let window: [Float]

    /// State updated from audio callback
    private var smoothedBands: [Float]
    private var smoothedVolume: Float = 0

    // MARK: Computed Properties

    /// Whether audio analysis is currently active
    public var isAnalyzing: Bool {
        _isAnalyzing
    }

    // MARK: Lifecycle

    /// Initialize the audio analyzer.
    ///
    /// - Parameters:
    ///   - engine: The AVAudioEngine to analyze audio from (optional for manual buffer processing)
    ///   - numberOfBands: Number of frequency bands to divide spectrum into (default: 8)
    ///   - smoothingFactor: Amount of smoothing applied to band levels, 0.0-1.0 (default: 0.0 for instant response)
    public init(
        engine: AVAudioEngine? = nil,
        numberOfBands: Int = 8,
        smoothingFactor: Float = 0.0,
    ) {
        self.engine = engine ?? AVAudioEngine()
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
        // If already analyzing, stop first to handle audio device changes
        if _isAnalyzing {
            stop()
        }

        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)

        // Remove any existing tap first (defensive)
        mainMixer.removeTap(onBus: 0)

        mainMixer.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(fftSize),
            format: format,
        ) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        _isAnalyzing = true
    }

    /// Stop analyzing audio and remove the audio tap.
    public func stop() {
        guard _isAnalyzing else { return }

        engine.mainMixerNode.removeTap(onBus: 0)
        _isAnalyzing = false

        // Reset frequency bands and smoothed state to zero
        for i in 0 ..< numberOfBands {
            frequencyBands[i] = 0
            smoothedBands[i] = 0
        }
        smoothedVolume = 0
        currentVolume = 0
    }

    /// Restart audio analysis (useful after audio device changes)
    public func restart() {
        stop()
        start()
    }

    // MARK: - Private Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard
            let channelData = buffer.floatChannelData,
            let setup = fftSetup else { return }

        let frameCount = Int(buffer.frameLength)

        // Edge case: invalid buffer size (can happen during device switch)
        guard frameCount > 0 else {
            // Reset to zeros when we get bad data
            Task { @MainActor in
                self.updateFrequencyBands([Float](repeating: 0, count: numberOfBands), volume: 0)
            }
            return
        }

        let channel = channelData[0]

        // Calculate RMS volume of the audio signal for noise gate
        var rmsVolume: Float = 0
        vDSP_rmsqv(channel, 1, &rmsVolume, vDSP_Length(frameCount))

        // Very gentle noise gate - only filter out true silence/noise floor
        // This is approximately -60dB, much more permissive than before
        let noiseGateThreshold: Float = 0.001

        // Simple boolean gate - either we process the signal or we don't
        let isAboveNoiseGate = rmsVolume >= noiseGateThreshold

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
        let bands = calculateFrequencyBands(from: magnitudes, isAboveNoiseGate: isAboveNoiseGate)

        // Update on main actor
        Task { @MainActor in
            self.updateFrequencyBands(bands, volume: rmsVolume)
        }
    }

    private func calculateFrequencyBands(from magnitudes: [Float], isAboveNoiseGate: Bool) -> [Float] {
        // If we're below the noise gate, just return zeros
        guard isAboveNoiseGate else {
            return [Float](repeating: 0, count: numberOfBands)
        }

        var bands = [Float](repeating: 0, count: numberOfBands)

        // Use LOGARITHMIC frequency distribution like the article suggests
        // This matches human hearing and music perception
        let nyquistFreq: Float = 22050.0 // Half of 44.1kHz
        let minFreq: Float = 440.0 // Start at 440Hz (upper bass/low mids)
        let maxFreq: Float = 10000.0 // End at 10kHz (upper treble)

        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logRange = logMax - logMin

        for band in 0 ..< numberOfBands {
            // Calculate frequency range for this band using log scale
            let logStart = logMin + (logRange * Float(band) / Float(numberOfBands))
            let logEnd = logMin + (logRange * Float(band + 1) / Float(numberOfBands))

            let freqStart = pow(10, logStart)
            let freqEnd = pow(10, logEnd)

            // Convert to FFT bin indices
            let startIndex = Int((freqStart / nyquistFreq) * Float(magnitudes.count))
            let endIndex = Int((freqEnd / nyquistFreq) * Float(magnitudes.count))

            var sum: Float = 0
            var count = 0

            for i in startIndex ..< min(endIndex, magnitudes.count) {
                sum += magnitudes[i]
                count += 1
            }

            if count > 0 {
                bands[band] = sum / Float(count)
            }

            // Apply frequency-dependent weighting to compensate for energy distribution
            // Lower frequencies (even 200Hz+) are still louder, so we apply inverse weighting
            let centerFreq = sqrt(freqStart * freqEnd) // Geometric mean

            // Inverse square law-inspired weighting: higher frequencies get boosted
            // This compensates for the natural energy drop-off
            let frequencyWeight = sqrt(centerFreq / minFreq)
            bands[band] *= frequencyWeight
        }

        // Apply Y-AXIS CUT: threshold out low amplitudes for dynamic range
        // This creates the "bars disappear and reappear" effect
        let maxMagnitude = bands.max() ?? 0.0

        // Edge case protection: if all bands are zero or very low, return zeros
        // This prevents stuck "solid block" when audio device switches
        guard maxMagnitude > 0.001 else {
            return [Float](repeating: 0, count: numberOfBands)
        }

        let threshold = maxMagnitude * 0.30 // Cut bottom 30% of the range

        for i in 0 ..< numberOfBands {
            // Apply threshold - anything below this becomes zero
            if bands[i] < threshold {
                bands[i] = 0.0
            } else {
                // Shift range so threshold becomes 0 and max becomes max
                let range = maxMagnitude - threshold
                if range > 0.001 { // Prevent divide by near-zero
                    bands[i] = (bands[i] - threshold) / range
                } else {
                    bands[i] = 0.0
                }
            }
        }

        // Now normalize the remaining values to 0-1 range
        for i in 0 ..< numberOfBands {
            // Light compression for visibility
            bands[i] = sqrtf(max(0, bands[i])) // Ensure non-negative for sqrt
        }

        return bands
    }

    private func updateFrequencyBands(_ newBands: [Float], volume: Float) {
        // Apply smoothing for less jittery animation
        for i in 0 ..< numberOfBands {
            smoothedBands[i] = smoothedBands[i] * smoothingFactor + newBands[i] * (1.0 - smoothingFactor)
            frequencyBands[i] = smoothedBands[i]
        }

        // Smooth the volume as well
        smoothedVolume = smoothedVolume * smoothingFactor + volume * (1.0 - smoothingFactor)
        currentVolume = smoothedVolume
    }
}
