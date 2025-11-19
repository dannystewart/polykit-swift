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
    // MARK: Properties

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

    // MARK: Lifecycle

    init() {
        setupInterruptionHandling()
    }

    // MARK: Functions

    // MARK: - Playback Control

    func play(_ item: any Playable, playbackURL: URL, isCached: Bool) {
        // If it's the same item and we have a player, just resume (unless we're at the end)
        if currentItem?.id == item.id, let player, currentTime < duration - 0.5 {
            player.play()
            isPlaying = true
            notifyStateChanged()
            return
        }

        // New item - setup new player
        cleanup()
        currentItem = item
        isLoading = true
        errorMessage = nil
        isStreamingPlayback = !isCached
        canSeek = isCached
        notifyStateChanged()

        // Pre-create artwork for this item if it has artwork data
        if let artworkData = item.artworkImageData {
            #if canImport(UIKit)
                if let image = UIImage(data: artworkData) {
                    let imageSize = image.size
                    currentItemArtwork = MPMediaItemArtwork(boundsSize: imageSize) { _ in
                        UIImage(data: artworkData) ?? UIImage()
                    }
                }
            #elseif canImport(AppKit)
                if let image = NSImage(data: artworkData) {
                    let imageSize = image.size
                    currentItemArtwork = MPMediaItemArtwork(boundsSize: imageSize) { _ in
                        NSImage(data: artworkData) ?? NSImage()
                    }
                }
            #endif
        } else {
            currentItemArtwork = nil
        }

        currentPlaybackURL = playbackURL

        let playerItem = AVPlayerItem(url: playbackURL)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        currentPlayerItemID = UUID().uuidString
        logger.debug("Created new player item: \(currentPlayerItemID!) for URL: \(playbackURL.lastPathComponent)")
        logger.debug("   Using \(isCached ? "CACHED" : "STREAMING") playback")

        setupObservers(playerItem: playerItem, player: newPlayer)

        newPlayer.play()
        isPlaying = true
        notifyStateChanged()
        // Don't call updateNowPlayingInfo() here - let the time observer handle it
        // to avoid dispatch queue conflicts with MPNowPlayingInfoCenter
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

    func togglePlayPause() {
        guard let player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        notifyStateChanged()
        // Don't call updateNowPlayingInfo() here - let the time observer handle it
    }

    func stop() {
        cleanup()
        currentItem = nil
        notifyStateChanged()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        guard canSeek else {
            logger.debug("Seeking disabled - file is streaming and not yet cached")
            return
        }

        logger.debug("Seeking to \(time)s (current: \(currentTime)s)")

        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        lastObservedTime = time

        player.seek(to: cmTime) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                logger.debug("   Seek completed: \(finished), new time: \(player.currentTime().seconds)")
                self.updateNowPlayingInfo()
            }
        }
    }

    func seekToStart() {
        guard let player else { return }
        let startTime = CMTime.zero
        lastObservedTime = 0

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
        canSeek = true
        notifyStateChanged()
    }

    func switchToCachedVersion(cachedURL: URL) {
        guard let player, let currentPlayerItem = player.currentItem else {
            logger.error("Cannot switch to cached version: no player or current item")
            return
        }

        // Verify the file exists
        guard FileManager.default.fileExists(atPath: cachedURL.path) else {
            logger.error("Cannot switch: cached file does not exist")
            return
        }

        // Save current playback state
        let currentPlaybackTime = currentPlayerItem.currentTime()
        let wasPlaying = isPlaying

        logger.info("Switching to cached version at \(currentPlaybackTime.seconds)s")

        // Create new player item - just replace immediately
        // Local files should load much faster than waiting for ready status
        let newPlayerItem = AVPlayerItem(url: cachedURL)

        // Clean up old observers before replacing the item
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        cancellables.removeAll()

        // Replace immediately
        logger.debug("Replacing player item")
        player.replaceCurrentItem(with: newPlayerItem)

        // Re-setup observers for the new item
        setupObservers(playerItem: newPlayerItem, player: player)

        // Seek to the position
        logger.debug("Seeking to \(currentPlaybackTime.seconds)s")
        player.seek(to: currentPlaybackTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }

                if finished {
                    if wasPlaying {
                        player.play()
                    }
                    logger.info("Successfully switched to cached version")
                    self.isStreamingPlayback = false
                    self.currentPlaybackURL = cachedURL
                    self.canSeek = true
                    self.notifyStateChanged()
                } else {
                    logger.error("Seek failed during switch")
                }
            }
        }
    }

    // MARK: - State Notification

    private func notifyStateChanged() {
        onStateChanged?()
    }

    // MARK: - Private Setup

    private func setupObservers(playerItem: AVPlayerItem, player: AVPlayer) {
        // Observe player status
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handlePlayerItemStatusChange(item)
            }
        }

        // Observe player time control status
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
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
                notifyStateChanged()
                // Don't call updateNowPlayingInfo() here - let the time observer handle it
            }
            .store(in: &cancellables)

        // Observe buffer status
        playerItem.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLikelyToKeepUp in
                guard let self else { return }
                if !isLikelyToKeepUp, isPlaying {
                    logger.warning("Buffering may cause playback issues")
                }
            }
            .store(in: &cancellables)

        playerItem.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isBufferEmpty in
                guard let self else { return }
                if isBufferEmpty, isPlaying {
                    logger.warning("Playback buffer is empty")
                }
            }
            .store(in: &cancellables)

        // Monitor loaded time ranges
        playerItem.publisher(for: \.loadedTimeRanges)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timeRanges in
                guard let self else { return }
                if !timeRanges.isEmpty {
                    let currentPlaybackTime = currentTime
                    for timeRange in timeRanges {
                        let range = timeRange.timeRangeValue
                        let start = range.start.seconds
                        let rangeDuration = range.duration.seconds

                        if currentPlaybackTime > start + rangeDuration - 5.0, isPlaying {
                            logger.warning("Approaching end of loaded data!")
                            logger.debug("   Current time: \(currentPlaybackTime)s")
                            logger.debug("   Loaded range: \(start)s - \(start + rangeDuration)s")
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Setup time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            // We're on main queue since we explicitly passed queue: .main
            // Don't use MainActor.assumeIsolated - it creates dispatch barriers that conflict with MPNowPlayingInfoCenter
            currentTime = time.seconds
            notifyStateChanged()

            // Update Now Playing info every second
            if time.seconds - lastNowPlayingUpdate >= 1.0 {
                lastNowPlayingUpdate = time.seconds
                updateNowPlayingInfo()
            }
        }

        // Observe when playback ends
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePlaybackEnded()
            }
            .store(in: &cancellables)

        // Observe playback stalls
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePlaybackStalled()
            }
            .store(in: &cancellables)

        // Observe error log entries
        NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleErrorLogEntry(notification)
            }
            .store(in: &cancellables)

        // Observe failed to play to end time
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleFailedToPlayToEndTime(notification)
            }
            .store(in: &cancellables)
    }

    // MARK: - Event Handlers

    private func handlePlayerItemStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            isLoading = false
            errorMessage = nil
            notifyStateChanged()
            // Update now playing info immediately when ready
            updateNowPlayingInfo()

        case .failed:
            isLoading = false
            isPlaying = false
            errorMessage = item.error?.localizedDescription ?? "Playback failed"
            notifyStateChanged()
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
                logger.debug("Player is waiting to play. Reason: \(reason.rawValue)")

                if reason == .toMinimizeStalls {
                    logger.debug("Player is buffering to minimize stalls")
                }
            }

        @unknown default:
            break
        }
    }

    private func handlePlaybackEnded() {
        logger.debug("Playback ended normally at time: \(currentTime)")

        // Mark playback as stopped so UIs can correctly reflect a non-playing state
        // when we reach the natural end of an item.
        isPlaying = false
        notifyStateChanged()

        onPlaybackEnded?()
    }

    private func handlePlaybackStalled() {
        logger.warning("PLAYBACK STALLED at time: \(currentTime), duration: \(duration)")

        guard !isHandlingStall else {
            logger.debug("Already handling stall, ignoring duplicate notification")
            return
        }

        isHandlingStall = true

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
                if currentItem.isPlaybackLikelyToKeepUp, isPlaying {
                    logger.debug("Buffer refilled, resuming playback")
                    player.play()
                } else if !isPlaying {
                    logger.debug("Playback was paused, not auto-resuming")
                } else {
                    logger.warning("Buffer still not ready after stall")
                }
            }

            isHandlingStall = false
        }
    }

    private func handleErrorLogEntry(_ notification: Notification) {
        guard
            let playerItem = notification.object as? AVPlayerItem,
            let errorLog = playerItem.errorLog() else { return }

        logger.error("ERROR LOG ENTRY at time: \(currentTime)")

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
        logger.error("FAILED TO PLAY TO END TIME at time: \(currentTime), duration: \(duration)")

        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            logger.error("Error: \(error.localizedDescription)")
            errorMessage = "Playback failed: \(error.localizedDescription)"
        }

        isPlaying = false

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
        } else if duration.isFinite, duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }

        // Use pre-created artwork (created once when item starts playing)
        if let artwork = currentItemArtwork ?? defaultArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func cleanup() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        statusObservation?.invalidate()
        statusObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        player?.pause()
        player = nil

        cancellables.removeAll()

        isPlaying = false
        currentTime = 0
        duration = 0
        isLoading = false
        currentPlaybackURL = nil
        isHandlingStall = false
        lastObservedTime = 0
        currentPlayerItemID = nil
        isStreamingPlayback = false
        canSeek = true
        currentItemArtwork = nil

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
                        // Interruption began - player auto-pauses
                        break

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
