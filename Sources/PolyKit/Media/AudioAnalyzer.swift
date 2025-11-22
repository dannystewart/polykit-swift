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
        guard !_isAnalyzing else { return }

        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)

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

        // Reset frequency bands to zero
        // These are nonisolated(unsafe) so we can access them here
        for i in 0 ..< numberOfBands {
            frequencyBands[i] = 0
        }
    }

    // MARK: - Private Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard
            let channelData = buffer.floatChannelData,
            let setup = fftSetup else { return }

        let frameCount = Int(buffer.frameLength)
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
        let maxFrequencyIndex = magnitudes.count

        // IGNORE frequencies below 300Hz - they're MASSIVE and skew everything
        // At 44.1kHz sample rate with 2048 FFT: each bin is ~21.5 Hz
        // 80Hz / 21.5Hz ≈ 3.7, so start at bin 4
        let nyquistFreq: Float = 22050.0 // Half of 44.1kHz
        let hzPerBin = nyquistFreq / Float(maxFrequencyIndex)
        let minFreq: Float = 300.0 // Ignore everything below 300Hz
        let minBin = Int(minFreq / hzPerBin)

        // Distribute bands from 80Hz to 20kHz
        let usableRange = maxFrequencyIndex - minBin
        let binsPerBand = usableRange / numberOfBands

        for band in 0 ..< numberOfBands {
            let startIndex = minBin + (band * binsPerBand)
            let endIndex = min(startIndex + binsPerBand, maxFrequencyIndex)

            var sum: Float = 0
            for i in startIndex ..< endIndex {
                sum += magnitudes[i]
            }

            // Average magnitude for this band
            let count = endIndex - startIndex
            if count > 0 {
                bands[band] = sum / Float(count)
            }
        }

        // Lower reference since we cut out the bass frequencies
        let referenceLevel: Float = 25.0

        for i in 0 ..< numberOfBands {
            // Normalize to reference
            bands[i] = bands[i] / referenceLevel

            // Light compression to expand dynamic range
            bands[i] = sqrtf(bands[i])

            // Moderate boost for dynamic range - natural levels without clipping
            bands[i] = min(bands[i] * 3.0, 1.0)
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
