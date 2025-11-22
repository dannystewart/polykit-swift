//
//  PlayerCore.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

@preconcurrency import AVFoundation
@preconcurrency import Combine
@preconcurrency import Foundation
@preconcurrency import MediaPlayer
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - PlayerCore

/// Clean audio player using AVAudioEngine for native audio analysis support
final class PlayerCore: @unchecked Sendable {
    // MARK: Properties

    // MARK: - Public State

    var currentItem: (any Playable)?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var canSeek: Bool = true
    var isLoading: Bool = false
    var errorMessage: String?

    /// Audio analysis - clean and simple!
    @ObservationIgnored nonisolated(unsafe) var frequencyBands: [Float] = []

    // MARK: - Callbacks

    var onPlaybackEnded: (() -> Void)?
    var onNeedsSwitchToCachedVersion: ((URL) -> Void)?
    var onStateChanged: (() -> Void)?

    // MARK: - Private State

    private let audioEngine: AVAudioEngine = .init()
    private let playerNode: AVAudioPlayerNode = .init()
    private var audioFile: AVAudioFile?
    private var audioAnalyzer: AudioAnalyzer?

    private var timeObserver: Timer?
    private var currentPlaybackURL: URL?
    private var isStreamingPlayback: Bool = false
    private var defaultArtworkImageName: String?
    private var defaultArtwork: MPMediaItemArtwork?
    private var currentItemArtwork: MPMediaItemArtwork?

    private var analysisCancellable: AnyCancellable?
    private var hasTriggeredEndCallback: Bool = false
    private var lastNowPlayingUpdateSecond: Int = -1
    private var currentSegmentStartTime: TimeInterval = 0

    // MARK: Lifecycle

    // MARK: - Initialization

    init() {
        setupAudioEngine()
        setupInterruptionHandling()
    }

    deinit {
        cleanup()
    }

    // MARK: Functions

    // MARK: - Playback Control

    func play(_ item: any Playable, playbackURL: URL, isCached: Bool) {
        // If same item, just resume
        if currentItem?.id == item.id, playerNode.isPlaying == false, currentTime < duration - 0.5 {
            playerNode.play()
            isPlaying = true
            startTimeObserver()
            notifyStateChanged()
            return
        }

        // New item - clean slate
        cleanup()
        currentItem = item
        isLoading = true
        errorMessage = nil
        isStreamingPlayback = !isCached
        canSeek = isCached
        currentPlaybackURL = playbackURL
        hasTriggeredEndCallback = false
        notifyStateChanged()

        // Create artwork
        setupArtwork(from: item)

        // Load and play audio file
        do {
            let file = try AVAudioFile(forReading: playbackURL)
            audioFile = file
            duration = Double(file.length) / file.fileFormat.sampleRate

            // Schedule file for playback (no completion handler - we detect end via time observer)
            playerNode.scheduleFile(file, at: nil)
            currentSegmentStartTime = 0 // Full file scheduled from start

            // Start playback
            playerNode.play()
            isPlaying = true
            isLoading = false
            startTimeObserver()

            // Setup audio analysis if not already done
            if audioAnalyzer == nil {
                setupAudioAnalysis()
            }

            logger.debug("[Playback] Started playing: \(playbackURL.lastPathComponent)")
            notifyStateChanged()

            // Update now playing immediately with the new track info
            // The time observer will update the elapsed time as playback progresses
            updateNowPlayingInfo()

        } catch {
            errorMessage = "Failed to load audio: \(error.localizedDescription)"
            isLoading = false
            logger.error("[Playback] Error: \(error.localizedDescription)")
            notifyStateChanged()
        }
    }

    func togglePlayPause() {
        if isPlaying {
            playerNode.pause()
            isPlaying = false
            stopTimeObserver()
        } else {
            playerNode.play()
            isPlaying = true
            startTimeObserver()
        }
        notifyStateChanged()
        updateNowPlayingInfo() // Update lock screen play/pause state
    }

    func stop() {
        cleanup()
        currentItem = nil
        // Clear now playing info when actually stopping
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        notifyStateChanged()
    }

    func seek(to time: TimeInterval) {
        guard canSeek, let file = audioFile else { return }

        let sampleRate = file.fileFormat.sampleRate
        let framePosition = AVAudioFramePosition(time * sampleRate)

        guard framePosition >= 0, framePosition < file.length else { return }

        playerNode.stop()

        // Calculate remaining frames
        let startFrame = framePosition
        let framesToPlay = file.length - startFrame

        guard framesToPlay > 0 else {
            handlePlaybackEnded()
            return
        }

        // Schedule from the seek position (no completion handler - time observer detects end)
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(framesToPlay),
            at: nil,
        )

        currentSegmentStartTime = time // Track where this segment starts in the file
        currentTime = time
        lastNowPlayingUpdateSecond = Int(time) // Track the new time for proper updates

        if isPlaying {
            playerNode.play()
        }

        notifyStateChanged()
        updateNowPlayingInfo()
    }

    func enableSeeking() {
        canSeek = true
        notifyStateChanged()
    }

    func seekToStart() {
        seek(to: 0)
    }

    func switchToCachedVersion(cachedURL: URL) {
        // For AVAudioFile approach, just switch to the cached file
        guard let item = currentItem else { return }
        let wasPlaying = isPlaying
        let savedTime = currentTime

        // Reload with cached file
        play(item, playbackURL: cachedURL, isCached: true)

        // Restore position
        if savedTime > 0 {
            seek(to: savedTime)
        }

        if !wasPlaying {
            playerNode.pause()
            isPlaying = false
        }
    }

    // MARK: - Configuration

    func setDefaultArtworkImageName(_ name: String?) {
        defaultArtworkImageName = name
        #if canImport(UIKit)
            if let name, let image = UIImage(named: name) {
                defaultArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else {
                defaultArtwork = nil
            }
        #elseif canImport(AppKit)
            if let name, let image = NSImage(named: name) {
                defaultArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else {
                defaultArtwork = nil
            }
        #endif
    }

    func setDefaultArtwork(_ artwork: MPMediaItemArtwork?) {
        defaultArtwork = artwork
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() {
        // Attach player node to engine
        audioEngine.attach(playerNode)

        // Connect player node to main mixer to output
        let mixer = audioEngine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: mixer, format: format)

        // Start the engine
        do {
            try audioEngine.start()
            logger.debug("[AudioEngine] Engine started successfully")
        } catch {
            logger.error("[AudioEngine] Failed to start: \(error.localizedDescription)")
        }
    }

    private func setupAudioAnalysis() {
        // Create analyzer and start it on a background thread (audio engine ops)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Create analyzer
            // Moderate smoothing so the visualization feels fast but still glides
            // between updates instead of stepping. 0.6 ≈ ~40ms time constant at 60 FPS.
            let analyzer = AudioAnalyzer(engine: audioEngine, numberOfBands: 8, smoothingFactor: 0.6)

            // Start analyzing the main mixer output
            analyzer.start()
            logger.debug("[AudioAnalysis] Started analyzing audio")

            // Assign analyzer and start timer on main thread
            DispatchQueue.main.async {
                self.audioAnalyzer = analyzer

                // Update frequency bands at 60 FPS
                self.analysisCancellable = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in
                        guard let self, let analyzer = audioAnalyzer else { return }
                        frequencyBands = analyzer.frequencyBands
                    }
            }
        }
    }

    // MARK: - Time Observer

    private func startTimeObserver() {
        stopTimeObserver()

        timeObserver = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }

            if
                let nodeTime = playerNode.lastRenderTime,
                let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
                let file = audioFile
            {
                let sampleRate = file.fileFormat.sampleRate
                // playerTime.sampleTime is relative to the currently scheduled segment
                // Add the segment start time to get absolute position in the file
                currentTime = currentSegmentStartTime + Double(playerTime.sampleTime) / sampleRate
                notifyStateChanged()

                // Check if we've reached the end naturally
                // Only fire once per track using the flag
                if isPlaying, duration > 0, currentTime >= duration - 0.15, !hasTriggeredEndCallback {
                    logger.debug("[Playback] Reached end of file at \(currentTime)s / \(duration)s")
                    hasTriggeredEndCallback = true
                    handlePlaybackEnded()
                }

                // Update Now Playing when the second changes
                let currentSecond = Int(currentTime)
                if currentSecond != lastNowPlayingUpdateSecond {
                    lastNowPlayingUpdateSecond = currentSecond
                    updateNowPlayingInfo()
                }
            } else {
                // If we can't get player time, keep currentTime as is (don't reset to 0)
                logger.debug("[TimeObserver] Could not get player time - keeping currentTime at \(currentTime)s")
            }
        }
    }

    private func stopTimeObserver() {
        timeObserver?.invalidate()
        timeObserver = nil
    }

    // MARK: - Helpers

    private func setupArtwork(from item: any Playable) {
        if let artworkData = item.artworkImageData {
            #if canImport(UIKit)
                if let image = UIImage(data: artworkData) {
                    currentItemArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                }
            #elseif canImport(AppKit)
                if let image = NSImage(data: artworkData) {
                    currentItemArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                }
            #endif
        } else {
            currentItemArtwork = nil
        }
    }

    private func handlePlaybackEnded() {
        isPlaying = false
        updateNowPlayingInfo()
        notifyStateChanged()
        onPlaybackEnded?()
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    private func cleanup() {
        stopTimeObserver()
        playerNode.stop()
        audioFile = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isLoading = false
        currentPlaybackURL = nil
        isStreamingPlayback = false
        canSeek = true
        currentItemArtwork = nil
        lastNowPlayingUpdateSecond = -1
        currentSegmentStartTime = 0
        // Don't clear now playing info here - let it transition smoothly between tracks
        // It will be cleared explicitly when stop() is called
    }

    // MARK: - Now Playing

    private func updateNowPlayingInfo() {
        guard let currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentItem.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentItem.artist

        if duration.isFinite, duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if let artwork = currentItemArtwork ?? defaultArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        logger.debug(
            "[NowPlaying] Updated info - title: \(currentItem.title), isPlaying: \(isPlaying), time: \(currentTime)",
        )

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Audio Session & Interruptions

    private func setupInterruptionHandling() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main,
            ) { [weak self] notification in
                guard let self else { return }

                // Extract data before entering MainActor context to avoid sending notification
                guard
                    let userInfo = notification.userInfo,
                    let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt

                // We're on main queue since we specified queue: .main
                MainActor.assumeIsolated {
                    switch type {
                    case .began:
                        // Interruption began (phone call, Siri, etc.)
                        // Audio engine is automatically paused by the system
                        // Update our state to reflect this
                        if self.isPlaying {
                            self.isPlaying = false
                            self.stopTimeObserver()
                            self.updateNowPlayingInfo()
                        }

                    case .ended:
                        guard let optionsValue else { return }
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        if options.contains(.shouldResume), !self.isPlaying {
                            // Resume playback
                            self.togglePlayPause()
                        }

                    @unknown default:
                        break
                    }
                }
            }
        #endif // os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    }
}
