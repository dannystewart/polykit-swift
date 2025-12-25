//
//  PlayerCore.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

@preconcurrency import AVFoundation
@preconcurrency import Combine
@preconcurrency import Foundation
@preconcurrency import MediaPlayer
import PolyKit
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

// MARK: - PlayerCore

/// Non-generic core player implementation that handles all AVPlayer interactions.
///
/// This class is intentionally non-generic to avoid Swift 6 Sendable issues
/// with capturing generic types in closures used by AVFoundation callbacks.
/// It works with `any Playable` existential types internally.
///
/// Note: Not marked with @MainActor because MPNowPlayingInfoCenter has strict
/// dispatch queue requirements that conflict with MainActor isolation.
/// All methods that interact with MPNowPlayingInfoCenter run on main queue explicitly.
final class PlayerCore: @unchecked Sendable {
    // MARK: - Public State

    var currentItem: (any Playable)?
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var canSeek: Bool = true
    var isLoading: Bool = false
    var errorMessage: String?

    // MARK: - Callbacks

    var onPlaybackEnded: (() -> Void)?
    var onNeedsSwitchToCachedVersion: ((URL) -> Void)?
    var onStateChanged: (() -> Void)?

    fileprivate nonisolated(unsafe) var audioFormat: AVAudioFormat?

    // MARK: - Private State

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    private var lastNowPlayingUpdate: TimeInterval = 0
    private var currentPlaybackURL: URL?
    private var isHandlingStall: Bool = false
    private var lastObservedTime: TimeInterval = 0
    private var currentPlayerItemID: String?
    private var isStreamingPlayback: Bool = false
    private var defaultArtworkImageName: String?
    private var defaultArtwork: MPMediaItemArtwork?
    private var currentItemArtwork: MPMediaItemArtwork?

    /// Audio analysis
    private nonisolated(unsafe) var audioAnalyzer: AudioAnalyzer?

    nonisolated var frequencyBands: [Float] {
        self.audioAnalyzer?.frequencyBands ?? []
    }

    init() {
        self.setupInterruptionHandling()
    }

    // MARK: - Playback Control

    func play(_ item: any Playable, playbackURL: URL, isCached: Bool) {
        // If it's the same item and we have a player, just resume (unless we're at the end)
        if self.currentItem?.id == item.id, let player, currentTime < duration - 0.5 {
            player.play()
            self.isPlaying = true
            self.notifyStateChanged()
            return
        }

        // New item - setup new player
        self.cleanup()
        self.currentItem = item
        self.isLoading = true
        self.errorMessage = nil
        self.isStreamingPlayback = !isCached
        self.canSeek = isCached
        self.notifyStateChanged()

        // Pre-create artwork for this item if it has artwork data
        if let artworkData = item.artworkImageData {
            #if canImport(UIKit)
                if let image = UIImage(data: artworkData) {
                    let imageSize = image.size
                    self.currentItemArtwork = MPMediaItemArtwork(boundsSize: imageSize) { _ in
                        UIImage(data: artworkData) ?? UIImage()
                    }
                }
            #elseif canImport(AppKit)
                if let image = NSImage(data: artworkData) {
                    let imageSize = image.size
                    self.currentItemArtwork = MPMediaItemArtwork(boundsSize: imageSize) { _ in
                        NSImage(data: artworkData) ?? NSImage()
                    }
                }
            #endif
        } else {
            self.currentItemArtwork = nil
        }

        self.currentPlaybackURL = playbackURL

        let playerItem = AVPlayerItem(url: playbackURL)
        let newPlayer = AVPlayer(playerItem: playerItem)

        // For local or fully cached files, favor immediacy over extra buffering.
        // Disabling `automaticallyWaitsToMinimizeStalling` reduces the delay
        // AVPlayer introduces after seeks or play/pause toggles in order to
        // build up a larger safety buffer. On local files this trade-off is
        // typically worth it for snappier +/- 5s skips.
        newPlayer.automaticallyWaitsToMinimizeStalling = !isCached

        player = newPlayer

        self.currentPlayerItemID = UUID().uuidString
        logger.debug("Created new player item \(self.currentPlayerItemID!) from \(isCached ? "cache" : "stream") for URL: \(playbackURL.lastPathComponent)")

        self.setupObservers(playerItem: playerItem, player: newPlayer)
        self.setupAudioAnalysis(player: newPlayer)

        newPlayer.play()
        self.isPlaying = true
        self.notifyStateChanged()

        // Update Now Playing info immediately with the new track's metadata
        // to create a seamless A → B transition instead of A → blank → B
        self.updateNowPlayingInfo()
    }

    // MARK: - Configuration

    func setDefaultArtworkImageName(_ name: String?) {
        self.defaultArtworkImageName = name
        #if canImport(UIKit)
            if let name, let image = UIImage(named: name) {
                self.defaultArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else {
                self.defaultArtwork = nil
            }
        #elseif canImport(AppKit)
            if let name, let image = NSImage(named: name) {
                self.defaultArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else {
                self.defaultArtwork = nil
            }
        #endif
    }

    func setDefaultArtwork(_ artwork: MPMediaItemArtwork?) {
        self.defaultArtwork = artwork
    }

    func togglePlayPause() {
        guard let player else { return }

        if self.isPlaying {
            player.pause()
            self.isPlaying = false
        } else {
            player.play()
            self.isPlaying = true
        }
        self.notifyStateChanged()
        // Don't call updateNowPlayingInfo() here - let the time observer handle it
    }

    func stop() {
        self.cleanup()
        self.currentItem = nil
        self.notifyStateChanged()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        guard self.canSeek else {
            logger.debug("Seeking is disabled; the file is streaming and not yet cached")
            return
        }

        logger.debug("Seeking to \(time)s (current: \(self.currentTime)s)")

        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        self.lastObservedTime = time

        player.seek(to: cmTime) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                logger.debug("Seek completed to \(player.currentTime().seconds)s")
                self.updateNowPlayingInfo()
            }
        }
    }

    func seekToStart() {
        guard let player else { return }
        let startTime = CMTime.zero
        self.lastObservedTime = 0

        player.seek(to: startTime) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, finished else { return }
                player.play()
                self.isPlaying = true
                self.currentTime = 0
            }
        }
    }

    func enableSeeking() {
        self.canSeek = true
        self.notifyStateChanged()
    }

    func switchToCachedVersion(cachedURL: URL) {
        guard let player, let currentPlayerItem = player.currentItem else {
            logger.error("Cannot switch to cached version: no player or current item")
            return
        }

        // Verify the file exists
        guard FileManager.default.fileExists(atPath: cachedURL.path) else {
            logger.error("Cannot switch to cached version: cached file does not exist")
            return
        }

        // Save current playback state
        let currentPlaybackTime = currentPlayerItem.currentTime()
        let wasPlaying = self.isPlaying

        logger.debug("Switching to cached version at \(currentPlaybackTime.seconds)s")

        // Create new player item - just replace immediately
        // Local files should load much faster than waiting for ready status
        let newPlayerItem = AVPlayerItem(url: cachedURL)

        // Clean up old observers before replacing the item
        self.statusObservation?.invalidate()
        self.statusObservation = nil
        self.timeControlStatusObservation?.invalidate()
        self.timeControlStatusObservation = nil
        self.cancellables.removeAll()

        // Replace immediately
        player.replaceCurrentItem(with: newPlayerItem)

        // Re-setup observers for the new item
        self.setupObservers(playerItem: newPlayerItem, player: player)

        // Seek to the position
        logger.debug("Seeking to \(currentPlaybackTime.seconds)s")
        player.seek(to: currentPlaybackTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }

                if finished {
                    if wasPlaying {
                        player.play()
                    }
                    logger.debug("Switched to cached version")
                    self.isStreamingPlayback = false
                    self.currentPlaybackURL = cachedURL
                    self.canSeek = true
                    self.notifyStateChanged()

                    // Re-setup audio analysis AFTER playback resumes
                    // This ensures the player item is fully ready and tapPrepare will be called
                    self.setupAudioAnalysis(player: player)
                } else {
                    logger.error("Seek failed during switch")
                }
            }
        }
    }

    // MARK: - Audio Tap Callbacks

    // swiftlint:disable:next function_parameter_count
    fileprivate nonisolated func processAudioTap(
        tap: MTAudioProcessingTap,
        numberFrames: CMItemCount,
        flags _: MTAudioProcessingTapFlags,
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>,
    ) {
        var timeRange = CMTimeRange()
        let status = MTAudioProcessingTapGetSourceAudio(
            tap,
            numberFrames,
            bufferList,
            flagsOut,
            &timeRange,
            numberFramesOut,
        )

        guard status == noErr else {
            logger.warning("[AudioTap] GetSourceAudio failed with status: \(status)")
            return
        }

        guard let analyzer = audioAnalyzer else {
            logger.warning("[AudioTap] No analyzer available")
            return
        }

        guard let format = audioFormat else {
            logger.warning("[AudioTap] No audio format available")
            return
        }

        // Create an AVAudioPCMBuffer from the AudioBufferList
        guard
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(numberFrames),
            ) else { return }

        pcmBuffer.frameLength = AVAudioFrameCount(numberFrames)

        // Copy audio data from the tap to the PCM buffer
        let audioBuffer = bufferList.pointee
        for bufferIndex in 0 ..< Int(audioBuffer.mNumberBuffers) {
            let buffer = UnsafeMutableAudioBufferListPointer(bufferList)[bufferIndex]
            if
                let channelData = pcmBuffer.floatChannelData?[bufferIndex],
                let sourceData = buffer.mData?.assumingMemoryBound(to: Float.self)
            {
                channelData.update(from: sourceData, count: Int(numberFrames))
            }
        }

        // Feed the buffer to the analyzer for FFT processing
        analyzer.processBuffer(pcmBuffer)
    }

    // MARK: - State Notification

    private func notifyStateChanged() {
        self.onStateChanged?()
    }

    // MARK: - Private Setup

    private func setupObservers(playerItem: AVPlayerItem, player: AVPlayer) {
        // Observe player status
        self.statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handlePlayerItemStatusChange(item)
            }
        }

        // Observe player time control status
        self.timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.handleTimeControlStatusChange(player)
            }
        }

        // Observe duration
        playerItem.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self, duration.isNumeric else { return }
                self.duration = duration.seconds
                self.notifyStateChanged()
                // Don't call updateNowPlayingInfo() here - let the time observer handle it
            }
            .store(in: &self.cancellables)

        // Observe buffer status
        playerItem.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLikelyToKeepUp in
                guard let self else { return }
                if !isLikelyToKeepUp, self.isPlaying {
                    logger.debug("File is buffering; playback may stall or stutter")
                }
            }
            .store(in: &self.cancellables)

        playerItem.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isBufferEmpty in
                guard let self else { return }
                if isBufferEmpty, self.isPlaying {
                    logger.debug("Playback buffer is empty")
                }
            }
            .store(in: &self.cancellables)

        // Monitor loaded time ranges
        playerItem.publisher(for: \.loadedTimeRanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timeRanges in
                guard let self else { return }
                if !timeRanges.isEmpty {
                    let currentPlaybackTime = self.currentTime
                    for timeRange in timeRanges {
                        let range = timeRange.timeRangeValue
                        let start = range.start.seconds
                        let rangeDuration = range.duration.seconds

                        if currentPlaybackTime > start + rangeDuration - 5.0, self.isPlaying {
                            logger.debug("Approaching end of loaded data at \(currentPlaybackTime)s; range: \(start)s to \(start + rangeDuration)s")
                        }
                    }
                }
            }
            .store(in: &self.cancellables)

        // Setup time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        self.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            // We're on main queue since we explicitly passed queue: .main
            // Don't use MainActor.assumeIsolated - it creates dispatch barriers that conflict with MPNowPlayingInfoCenter
            self.currentTime = time.seconds
            self.notifyStateChanged()

            // Update Now Playing info every second
            if time.seconds - self.lastNowPlayingUpdate >= 1.0 {
                self.lastNowPlayingUpdate = time.seconds
                self.updateNowPlayingInfo()
            }
        }

        // Observe when playback ends
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePlaybackEnded()
            }
            .store(in: &self.cancellables)

        // Observe playback stalls
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePlaybackStalled()
            }
            .store(in: &self.cancellables)

        // Observe error log entries
        NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleErrorLogEntry(notification)
            }
            .store(in: &self.cancellables)

        // Observe failed to play to end time
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleFailedToPlayToEndTime(notification)
            }
            .store(in: &self.cancellables)
    }

    private nonisolated func setupAudioAnalysis(player: AVPlayer) {
        guard let playerItem = player.currentItem else {
            logger.warning("[AudioAnalysis] No current item, cannot setup audio analysis")
            return
        }

        logger.debug("[AudioAnalysis] Setting up audio analysis")

        // Create analyzer FIRST, synchronously on main actor, to eliminate race condition
        // where tap callbacks might fire before analyzer is assigned
        Task { @MainActor in
            self.audioAnalyzer = AudioAnalyzer(engine: nil, numberOfBands: 8, smoothingFactor: 0.82)
            logger.debug("[AudioAnalysis] AudioAnalyzer created and assigned")
        }

        // Then setup the audio tap asynchronously
        // By the time the tap starts firing, the analyzer will definitely exist
        Task { @MainActor in
            // Load audio tracks
            let audioTracks = try? await playerItem.asset.load(.tracks)
            let audioTrack = audioTracks?.first(where: { $0.mediaType == .audio })

            guard let firstAudioTrack = audioTrack else {
                logger.warning("[AudioAnalysis] No audio track found")
                return
            }

            // Create audio mix and tap
            let audioMix = AVMutableAudioMix()
            let inputParams = AVMutableAudioMixInputParameters(track: firstAudioTrack)

            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                init: tapInit,
                finalize: tapFinalize,
                prepare: tapPrepare,
                unprepare: tapUnprepare,
                process: tapProcess,
            )

            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(
                kCFAllocatorDefault,
                &callbacks,
                kMTAudioProcessingTapCreationFlag_PreEffects,
                &tap,
            )

            if status == noErr, let tap {
                inputParams.audioTapProcessor = tap
                audioMix.inputParameters = [inputParams]
                playerItem.audioMix = audioMix
                logger.debug("[AudioAnalysis] Audio tap attached successfully")
            } else {
                logger.error("[AudioAnalysis] Failed to create audio processing tap: \(status)")
            }
        }
    }

    // MARK: - Event Handlers

    private func handlePlayerItemStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            self.isLoading = false
            self.errorMessage = nil
            self.notifyStateChanged()
            // Update now playing info immediately when ready
            self.updateNowPlayingInfo()

        case .failed:
            self.isLoading = false
            self.isPlaying = false
            self.errorMessage = item.error?.localizedDescription ?? "Playback failed"
            self.notifyStateChanged()
            logger.error("Player item failed: \(item.error?.localizedDescription ?? "unknown error")")

        case .unknown:
            break

        @unknown default:
            break
        }
    }

    private func handleTimeControlStatusChange(_ player: AVPlayer) {
        switch player.timeControlStatus {
        case .playing:
            logger.debug("Player is playing")

        case .paused:
            logger.debug("Player is paused")

        case .waitingToPlayAtSpecifiedRate:
            if let reason = player.reasonForWaitingToPlay {
                logger.debug("Player is waiting to play: \(reason.rawValue)")

                if reason == .toMinimizeStalls {
                    logger.debug("Player is buffering to minimize stalls")
                }
            }

        @unknown default:
            break
        }
    }

    private func handlePlaybackEnded() {
        // Mark playback as stopped so UIs can correctly reflect a non-playing state
        // when we reach the natural end of an item.
        self.isPlaying = false
        self.notifyStateChanged()

        self.onPlaybackEnded?()
    }

    private func handlePlaybackStalled() {
        logger.warning("Playback stalled at time: \(self.currentTime), duration: \(self.duration)")

        guard !self.isHandlingStall else {
            logger.debug("Already handling stall; ignoring duplicate notification")
            return
        }

        self.isHandlingStall = true

        // Log detailed player state
        if let player, let currentItem = player.currentItem {
            logger.debug("Player state:")
            logger.debug("  - Status: \(currentItem.status.rawValue)")
            logger.debug("  - Playback likely to keep up: \(currentItem.isPlaybackLikelyToKeepUp)")
            logger.debug("  - Playback buffer empty: \(currentItem.isPlaybackBufferEmpty)")
            logger.debug("  - Playback buffer full: \(currentItem.isPlaybackBufferFull)")

            if let accessLog = currentItem.accessLog() {
                for event in accessLog.events {
                    logger.debug("Access log event:")
                    logger.debug("  - Stalled count: \(event.numberOfStalls)")
                    logger.debug("  - Bytes transferred: \(event.numberOfBytesTransferred)")
                }
            }

            if let errorLog = currentItem.errorLog() {
                for event in errorLog.events {
                    logger.error("Error log event:")
                    logger.error("  - Error: \(event.errorDomain) - \(event.errorStatusCode)")
                    if let comment = event.errorComment {
                        logger.error("  - Comment: \(comment)")
                    }
                }
            }
        }

        // Try to recover from stall
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }

            if let player, let currentItem = player.currentItem {
                if currentItem.isPlaybackLikelyToKeepUp, self.isPlaying {
                    logger.debug("Buffer refilled, resuming playback")
                    player.play()
                } else if !self.isPlaying {
                    logger.debug("Playback was paused, not auto-resuming")
                } else {
                    logger.warning("Buffer still not ready after stall")
                }
            }

            self.isHandlingStall = false
        }
    }

    private func handleErrorLogEntry(_ notification: Notification) {
        guard
            let playerItem = notification.object as? AVPlayerItem,
            let errorLog = playerItem.errorLog() else { return }

        logger.error("Error log entry at time: \(self.currentTime)")

        for event in errorLog.events {
            logger.error("Error event:")
            logger.error("  - Domain: \(event.errorDomain)")
            logger.error("  - Status code: \(event.errorStatusCode)")
            if let comment = event.errorComment {
                logger.error("  - Comment: \(comment)")
            }
            if let uri = event.uri {
                logger.error("  - URI: \(uri)")
            }
        }
    }

    private func handleFailedToPlayToEndTime(_ notification: Notification) {
        logger.error("Failed to play to end time: \(self.currentTime), duration: \(self.duration)")

        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            logger.error("Error: \(error.localizedDescription)")
            self.errorMessage = "Playback failed: \(error.localizedDescription)"
        }

        self.isPlaying = false

        // Log player item state
        if let player, let currentItem = player.currentItem {
            logger.error("Player item state:")
            logger.error("  - Status: \(currentItem.status.rawValue)")

            if let error = currentItem.error {
                logger.error("  - Item error: \(error.localizedDescription)")
            }
        }
    }

    private func updateNowPlayingInfo() {
        guard let currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentItem.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentItem.artist

        // Add duration only when known and valid. Prefer item's declared duration for immediacy.
        let declaredDuration = currentItem.duration
        if declaredDuration.isFinite, declaredDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = declaredDuration
        } else if self.duration.isFinite, self.duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = self.duration
        }

        // Use pre-created artwork (created once when item starts playing)
        if let artwork = currentItemArtwork ?? defaultArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        // Set current playback position and rate for lock screen controls
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func cleanup() {
        if let timeObserver {
            self.player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        self.statusObservation?.invalidate()
        self.statusObservation = nil

        self.timeControlStatusObservation?.invalidate()
        self.timeControlStatusObservation = nil

        self.player?.pause()
        self.player = nil

        self.cancellables.removeAll()

        self.isPlaying = false
        self.currentTime = 0
        self.duration = 0
        self.isLoading = false
        self.currentPlaybackURL = nil
        self.isHandlingStall = false
        self.lastObservedTime = 0
        self.currentPlayerItemID = nil
        self.isStreamingPlayback = false
        self.canSeek = true
        self.currentItemArtwork = nil

        // Clear audio analysis state when switching tracks
        self.audioFormat = nil
        self.audioAnalyzer = nil // Clear analyzer so it gets recreated fresh for new track
        logger.debug("[AudioAnalysis] Cleared analyzer and format in cleanup")

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

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
                        // Interruption began - AVPlayer auto-pauses, but we need to sync our state
                        self.isPlaying = false
                        self.notifyStateChanged()
                        self.updateNowPlayingInfo()

                    case .ended:
                        guard let optionsValue else { return }
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        if options.contains(.shouldResume) {
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

// MARK: - MTAudioProcessingTap Callbacks

private func tapInit(
    tap _: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap _: MTAudioProcessingTap) {
    // Cleanup if needed
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames _: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>,
) {
    let clientInfo = MTAudioProcessingTapGetStorage(tap)
    let core = Unmanaged<PlayerCore>.fromOpaque(clientInfo).takeUnretainedValue()

    // Store the audio format for creating buffers later
    let format = AVAudioFormat(streamDescription: processingFormat)
    core.audioFormat = format
    logger.debug("[AudioTap] Prepare called, audio format set: \(format?.sampleRate ?? 0) Hz, \(format?.channelCount ?? 0) channels")
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let clientInfo = MTAudioProcessingTapGetStorage(tap)
    _ = Unmanaged<PlayerCore>.fromOpaque(clientInfo).takeUnretainedValue()
    // Don't clear audioFormat - it persists across pause/play cycles
    // Only gets cleared when switching tracks (via cleanup())
    logger.debug("[AudioTap] Unprepare called, keeping audio format")
}

// swiftlint:disable:next function_parameter_count
private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>,
) {
    let clientInfo = MTAudioProcessingTapGetStorage(tap)
    let core = Unmanaged<PlayerCore>.fromOpaque(clientInfo).takeUnretainedValue()

    core.processAudioTap(
        tap: tap,
        numberFrames: numberFrames,
        flags: flags,
        bufferList: bufferListInOut,
        numberFramesOut: numberFramesOut,
        flagsOut: flagsOut,
    )
}
