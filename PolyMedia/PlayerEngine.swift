//
//  PlayerEngine.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import AVFoundation
import Foundation
import MediaPlayer
import Observation
import PolyKit

// MARK: - Logger

let logger: PolyLog = .init()

// MARK: - RepeatMode

/// Playback repeat mode
public enum RepeatMode {
    /// No repeat - stop at end of playlist
    case off

    /// Repeat current track indefinitely
    case one

    /// Repeat entire playlist
    case all
}

// MARK: - CacheEntry

/// Cache entry for tracking cached media items
private struct CacheEntry {
    let id: Int
    let size: Int64
    let lastPlayed: Date
}

// MARK: - PlayerEngine

/// Generic media playback manager that works with any type conforming to `Playable`.
///
/// Provides full-featured audio playback with:
/// - Streaming and local file playback
/// - Automatic caching with LRU management
/// - Playlist management with shuffle and repeat
/// - Lock screen/Control Center integration
/// - Seeking support (disabled during streaming until cached)
///
/// This class uses composition to separate concerns: it delegates all AVPlayer
/// interactions to a non-generic `PlayerCore`, avoiding Swift 6 Sendable
/// issues with generic types in closures.
@MainActor
@Observable
public class PlayerEngine<T: Playable> {
    public var maxCacheSizeBytes: Int64 = 500000000 { // 500 MB default
        didSet {
            UserDefaults.standard.set(maxCacheSizeBytes, forKey: "PlayerEngine_maxCacheSizeBytes")
            pruneCache()
        }
    }

    public var cachedItemIDs: Set<Int> = []
    public var favoriteCachedIDs: Set<Int> = []
    public var selectedItemForDetail: T?

    // Playlist management
    public var playlist: [T] = []
    public var isShuffleEnabled: Bool = false
    public var repeatMode: RepeatMode = .off

    // MARK: - Public Properties (stored for @Observable tracking)

    public private(set) var currentItem: T?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var canSeek: Bool = true
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String?

    /// Name of an image in the host app's asset catalog to use as default
    /// artwork for Now Playing info when the current item has no artwork.
    public var defaultArtworkImageName: String? {
        didSet {
            core.setDefaultArtworkImageName(defaultArtworkImageName)
        }
    }

    /// Preconstructed artwork object to use for Now Playing info (preferred).
    /// Setting this overrides any image name set in `defaultArtworkImageName`.
    public var defaultArtwork: MPMediaItemArtwork? {
        didSet {
            core.setDefaultArtwork(defaultArtwork)
        }
    }

    // MARK: - Private Properties

    private let core: PlayerCore
    private var lastPlayedTimes: [Int: Date] = [:]
    private var currentIndex: Int = 0
    private var originalPlaylist: [T] = []
    private var currentlyDownloadingItemID: Int?

    /// Canonical playlist as last provided by the host app.
    ///
    /// This reflects the app's "intended" ordering of items (for example,
    /// a directory listing, search results, or a curated queue). The engine
    /// uses this for repeat and navigation, but higher-level behaviors like
    /// shuffle are owned by the host app.
    public var canonicalPlaylist: [T] {
        originalPlaylist
    }

    /// Current frequency band levels for visualization (0.0 to 1.0)
    public var frequencyBands: [Float] {
        core.frequencyBands
    }

    public var hasCurrentItem: Bool {
        currentItem != nil
    }

    public var hasNextTrack: Bool {
        guard !playlist.isEmpty else { return false }
        return repeatMode == .all || currentIndex < playlist.count - 1
    }

    public var hasPreviousTrack: Bool {
        guard !playlist.isEmpty else { return false }
        return repeatMode == .all || currentIndex > 0
    }

    public var currentCacheSizeBytes: Int64 {
        var totalSize: Int64 = 0

        for itemID in cachedItemIDs {
            let fileURL = getCachedFileURL(for: itemID)
            if
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                let fileSize = attributes[.size] as? Int64
            {
                totalSize += fileSize
            }
        }

        return totalSize
    }

    public var formattedCacheSize: String {
        let totalSize = currentCacheSizeBytes
        let maxSize = maxCacheSizeBytes

        // Format as MB or GB
        let megabytes = Double(totalSize) / 1048576.0
        let maxMegabytes = Double(maxSize) / 1048576.0

        if megabytes < 1024, maxMegabytes < 1024 {
            return String(format: "%.1f MB / %.0f MB", megabytes, maxMegabytes)
        } else {
            let gigabytes = megabytes / 1024.0
            let maxGigabytes = maxMegabytes / 1024.0
            return String(format: "%.2f GB / %.1f GB", gigabytes, maxGigabytes)
        }
    }

    // MARK: - Initialization

    public init() {
        core = PlayerCore()
        configureAudioSession()
        setupRemoteCommandCenter()
        loadCacheSettings()
        core.setDefaultArtworkImageName(defaultArtworkImageName)

        // Setup core callbacks
        core.onPlaybackEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }

        core.onStateChanged = { [weak self] in
            self?.syncStateFromCore()
        }

        // Initial state sync
        syncStateFromCore()
    }

    // MARK: - Playback Control

    public func play(_ item: T, in itemList: [T] = []) {
        // Update playlist if provided
        if !itemList.isEmpty {
            originalPlaylist = itemList
            playlist = itemList
            currentIndex = playlist.firstIndex(where: { $0.id == item.id }) ?? 0
        }

        guard let audioURL = item.audioURL else {
            core.errorMessage = "No audio URL available"
            core.isLoading = false
            return
        }

        // Determine which URL to use for playback
        let playbackURL: URL
        let treatedAsCached: Bool // Whether to enable seeking (cached or local file)

        if audioURL.isFileURL {
            // Local or iCloud file - never cache these
            // For iCloud files, iOS/macOS handles downloading and caching automatically
            playbackURL = audioURL
            treatedAsCached = true // Enable seeking immediately (iCloud downloads are handled by AVPlayer)
            logger.debug("Using local file; seeking is enabled, no manual caching needed")
        } else {
            // Remote HTTP(S) URL - check if we have a cached copy
            let isCached = cachedItemIDs.contains(item.id)

            if isCached {
                // Use our cached copy from previous download
                playbackURL = getCachedFileURL(for: item.id)
                treatedAsCached = true
                logger.debug("Using cached file from previous download; seeking is enabled")
            } else {
                // Stream the remote file and download in background
                playbackURL = audioURL
                treatedAsCached = false
                logger.debug("Streaming remote URL; seeking disabled until file is cached")

                // Start background download for caching
                if currentlyDownloadingItemID != item.id {
                    currentlyDownloadingItemID = item.id
                    logger.debug("Starting background download for remote file")
                    downloadItem(item, enablePlaybackOptimizations: true, markAsFavorite: false)
                }
            }

            // Track playback for LRU cache (only for remote files that get cached)
            lastPlayedTimes[item.id] = Date()
            saveLastPlayedTimes()
        }

        // Activate audio session before playback begins
        activateAudioSession()

        // Delegate to core
        core.play(item, playbackURL: playbackURL, isCached: treatedAsCached)

        // Ensure remote command center is enabled for playback
        enableRemoteCommandCenter()
    }

    public func togglePlayPause() {
        core.togglePlayPause()
    }

    /// Smart play/pause that handles edge cases for better UX.
    ///
    /// Behavior:
    /// - If no current item but playlist exists: starts playback from first track
    /// - If at end of current track (within threshold): restarts current track
    /// - Otherwise: toggles play/pause state
    ///
    /// This provides more intuitive behavior than plain `togglePlayPause()`,
    /// especially when triggered by hardware media keys or play buttons at the
    /// end of playback.
    ///
    /// - Parameter restartThreshold: Time in seconds from the end of a track to
    ///   trigger restart behavior. Default is 0.5 seconds.
    public func smartPlayPause(restartThreshold: TimeInterval = 0.5) {
        // If no item is playing but we have a playlist, start from the beginning
        if !hasCurrentItem {
            guard let first = playlist.first else { return }
            play(first, in: playlist)
            return
        }

        // If we're effectively at the end of the track, restart it
        if duration > 0, currentTime >= duration - restartThreshold {
            if let current = currentItem {
                play(current, in: playlist)
            } else {
                seek(to: 0)
            }
        } else {
            // Normal toggle behavior
            togglePlayPause()
        }
    }

    public func stop() {
        core.stop()
        disableRemoteCommandCenter()
        deactivateAudioSession()
    }

    public func seek(to time: TimeInterval) {
        core.seek(to: time)
    }

    /// Seeks forward or backward by the specified number of seconds.
    ///
    /// The resulting time is clamped to `[0, duration]` to ensure valid playback position.
    ///
    /// - Parameter offset: Time offset in seconds. Positive values seek forward, negative values seek backward.
    public func seekBy(offset: TimeInterval) {
        let newTime = max(0, min(currentTime + offset, duration))
        seek(to: newTime)
    }

    public func nextTrack() {
        guard !playlist.isEmpty else { return }

        // Manual next track should override repeat one
        switch repeatMode {
        case .all:
            currentIndex = (currentIndex + 1) % playlist.count
            play(playlist[currentIndex])

        case .off, .one:
            // Explicit next track overrides repeat one
            if currentIndex < playlist.count - 1 {
                currentIndex += 1
                play(playlist[currentIndex])
            } else {
                stop()
            }
        }
    }

    public func previousTrack() {
        guard !playlist.isEmpty else { return }

        // If we're more than 3 seconds in, restart current track
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        // Otherwise go to previous track - explicit previous overrides repeat one
        switch repeatMode {
        case .all:
            currentIndex = (currentIndex - 1 + playlist.count) % playlist.count
            play(playlist[currentIndex])

        case .off, .one:
            // Explicit previous track overrides repeat one
            if currentIndex > 0 {
                currentIndex -= 1
                play(playlist[currentIndex])
            }
        }
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .one
        case .one: repeatMode = .all
        case .all: repeatMode = .off
        }
    }

    /// Update the current playlist to a new ordering/content while keeping
    /// the same `currentItem` whenever possible. This is primarily used by
    /// host apps that present an editable queue UI.
    ///
    /// - Parameter newPlaylist: The new canonical playlist ordering.
    public func updatePlaylistKeepingCurrentItem(_ newPlaylist: [T]) {
        originalPlaylist = newPlaylist
        playlist = newPlaylist

        if
            let current = currentItem,
            let index = playlist.firstIndex(where: { $0.id == current.id })
        {
            currentIndex = index
        } else {
            currentIndex = 0
        }
    }

    /// Adopt a new playback order for the current playlist without changing
    /// the canonical playlist provided by the host app.
    ///
    /// This is a low-level helper intended for app-specific behaviors such as
    /// shuffle. Apps decide *what* the new order should be (shuffled, sorted,
    /// filtered, etc.) and the engine ensures that `currentItem` stays aligned
    /// with the new ordering.
    ///
    /// - Parameter newOrder: The desired playback order for the existing items.
    public func adoptPlaylistOrder(_ newOrder: [T]) {
        playlist = newOrder

        if
            let current = currentItem,
            let index = playlist.firstIndex(where: { $0.id == current.id })
        {
            currentIndex = index
        } else {
            currentIndex = 0
        }
    }

    // MARK: - Cache Management

    public func clearCache() {
        let nonFavoriteIDs = cachedItemIDs.subtracting(favoriteCachedIDs)
        for itemID in nonFavoriteIDs {
            let fileURL = getCachedFileURL(for: itemID)
            try? FileManager.default.removeItem(at: fileURL)
        }

        cachedItemIDs = favoriteCachedIDs
        saveCachedItems()
    }

    public func cacheItemAsFavorite(_ item: T) {
        let itemID = item.id

        if cachedItemIDs.contains(itemID) {
            favoriteCachedIDs.insert(itemID)
            saveCachedItems()
            return
        }

        // Don't try to cache local files - they're already available
        guard let audioURL = item.audioURL, !audioURL.isFileURL else {
            return
        }

        downloadItem(item, enablePlaybackOptimizations: false, markAsFavorite: true)
    }

    public func uncacheItemFromFavorites(_ item: T) {
        favoriteCachedIDs.remove(item.id)
        saveCachedItems()
    }

    public func syncFavorites(_ favorites: [T]) {
        let favoriteIDs = Set(favorites.map(\.id))
        favoriteCachedIDs = favoriteCachedIDs.intersection(favoriteIDs)

        for item in favorites {
            let itemID = item.id

            // Skip local files - they don't need caching
            if let audioURL = item.audioURL, audioURL.isFileURL {
                continue
            }

            if !cachedItemIDs.contains(itemID) {
                downloadItem(item, enablePlaybackOptimizations: false, markAsFavorite: true)
            } else {
                favoriteCachedIDs.insert(itemID)
            }
        }

        saveCachedItems()
    }

    // MARK: - State Synchronization

    private func syncStateFromCore() {
        let wasPlaying = isPlaying

        currentItem = core.currentItem as? T
        isPlaying = core.isPlaying
        currentTime = core.currentTime
        duration = core.duration
        canSeek = core.canSeek
        isLoading = core.isLoading
        errorMessage = core.errorMessage

        // Redundantly ensure Now Playing playback rate matches our current state.
        // This guards against any timing quirks in the core's own updates so the
        // lock screen button reflects the real play/pause state.
        if isPlaying != wasPlaying {
            syncNowPlayingPlaybackRate()
        }
    }

    // MARK: - Private Methods

    private func handlePlaybackEnded() {
        switch repeatMode {
        case .one:
            core.seekToStart()

        case .all:
            nextTrack()

        case .off:
            if hasNextTrack {
                nextTrack()
            }
        }
    }

    private func getCacheDirectory() -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let mediaCacheDir = cacheDir.appendingPathComponent("PlayerEngine", isDirectory: true)

        if !FileManager.default.fileExists(atPath: mediaCacheDir.path) {
            try? FileManager.default.createDirectory(at: mediaCacheDir, withIntermediateDirectories: true)
        }

        return mediaCacheDir
    }

    private func getCachedFileURL(for itemID: Int) -> URL {
        getCacheDirectory().appendingPathComponent("\(itemID).mp3")
    }

    private func saveCachedItems() {
        UserDefaults.standard.set(Array(cachedItemIDs), forKey: "PlayerEngine_cachedItemIDs")
        UserDefaults.standard.set(Array(favoriteCachedIDs), forKey: "PlayerEngine_favoriteCachedIDs")
    }

    private func loadCacheSettings() {
        let savedMaxSize = UserDefaults.standard.object(forKey: "PlayerEngine_maxCacheSizeBytes") as? Int64
        maxCacheSizeBytes = savedMaxSize ?? 500000000

        if let idArray = UserDefaults.standard.array(forKey: "PlayerEngine_cachedItemIDs") as? [Int] {
            cachedItemIDs = Set(idArray)
        }

        if let favoriteIDArray = UserDefaults.standard.array(forKey: "PlayerEngine_favoriteCachedIDs") as? [Int] {
            favoriteCachedIDs = Set(favoriteIDArray)
        }

        if let savedTimes = UserDefaults.standard.dictionary(forKey: "PlayerEngine_lastPlayedTimes") as? [String: Date] {
            lastPlayedTimes = savedTimes.reduce(into: [:]) { result, entry in
                if let id = Int(entry.key) {
                    result[id] = entry.value
                }
            }
        }
    }

    private func saveLastPlayedTimes() {
        let stringKeyDict = lastPlayedTimes.reduce(into: [:]) { result, entry in
            result[String(entry.key)] = entry.value
        }
        UserDefaults.standard.set(stringKeyDict, forKey: "PlayerEngine_lastPlayedTimes")
    }

    private func downloadItem(_ item: T, enablePlaybackOptimizations: Bool, markAsFavorite: Bool) {
        guard let audioURL = item.audioURL else { return }

        let itemID = item.id

        let task = URLSession.shared.downloadTask(with: audioURL) { [weak self] tempURL, _, error in
            guard let tempURL, error == nil else { return }

            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let mediaCacheDir = cacheDir.appendingPathComponent("PlayerEngine", isDirectory: true)
            let cachedFileURL = mediaCacheDir.appendingPathComponent("\(itemID).mp3")

            do {
                if !FileManager.default.fileExists(atPath: mediaCacheDir.path) {
                    try FileManager.default.createDirectory(at: mediaCacheDir, withIntermediateDirectories: true)
                }

                if FileManager.default.fileExists(atPath: cachedFileURL.path) {
                    try FileManager.default.removeItem(at: cachedFileURL)
                }

                try FileManager.default.moveItem(at: tempURL, to: cachedFileURL)

                // Verify the file is actually there and readable
                guard
                    FileManager.default.fileExists(atPath: cachedFileURL.path),
                    FileManager.default.isReadableFile(atPath: cachedFileURL.path) else
                {
                    logger.error("File was moved but not accessible at: \(cachedFileURL.path)")
                    return
                }

                // Small delay to ensure filesystem sync
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard let self else { return }

                    self.cachedItemIDs.insert(itemID)
                    self.lastPlayedTimes[itemID] = Date()
                    self.saveCachedItems()
                    self.saveLastPlayedTimes()

                    if markAsFavorite {
                        self.favoriteCachedIDs.insert(itemID)
                        self.saveCachedItems()
                    }

                    self.pruneCache()

                    if enablePlaybackOptimizations {
                        logger.info("Download complete for item \(itemID) (optimized)")

                        if self.currentItem?.id == itemID {
                            logger.info("Still playing - switching to cached version")
                            self.core.enableSeeking()
                            self.core.switchToCachedVersion(cachedURL: cachedFileURL)
                        }

                        if self.currentlyDownloadingItemID == itemID {
                            self.currentlyDownloadingItemID = nil
                        }
                    } else {
                        logger.info("Download complete for item \(itemID)")
                    }
                }
            } catch {
                logger.error("Failed to cache item: \(error)")
                DispatchQueue.main.async {
                    guard let self else { return }
                    if enablePlaybackOptimizations, self.currentlyDownloadingItemID == itemID {
                        self.currentlyDownloadingItemID = nil
                    }
                }
            }
        }

        task.resume()
    }

    private func pruneCache() {
        let currentSize = currentCacheSizeBytes
        guard currentSize > maxCacheSizeBytes else { return }

        logger.info("Cache is over the limit (\(currentSize) > \(maxCacheSizeBytes)), pruning...")

        let nonFavoriteIDs = cachedItemIDs.subtracting(favoriteCachedIDs)
        var entries = [CacheEntry]()

        for itemID in nonFavoriteIDs {
            let fileURL = getCachedFileURL(for: itemID)

            if
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                let fileSize = attributes[.size] as? Int64
            {
                let lastPlayed = lastPlayedTimes[itemID] ?? Date.distantPast
                entries.append(CacheEntry(id: itemID, size: fileSize, lastPlayed: lastPlayed))
            }
        }

        entries.sort { $0.lastPlayed < $1.lastPlayed }

        var sizeToFree = currentSize - maxCacheSizeBytes
        var deletedCount = 0

        for entry in entries {
            guard sizeToFree > 0 else { break }

            let fileURL = getCachedFileURL(for: entry.id)
            do {
                try FileManager.default.removeItem(at: fileURL)
                cachedItemIDs.remove(entry.id)
                lastPlayedTimes.removeValue(forKey: entry.id)
                sizeToFree -= entry.size
                deletedCount += 1
                logger.debug("Deleted item \(entry.id) (last played: \(entry.lastPlayed), size: \(entry.size) bytes)")
            } catch {
                logger.error("Failed to delete item \(entry.id): \(error)")
            }
        }

        if deletedCount > 0 {
            saveCachedItems()
            saveLastPlayedTimes()
            logger.info("Pruned \(deletedCount) items")
        }
    }

    /// Configure audio session category and mode without activating it.
    /// The session will be activated when playback actually begins.
    private func configureAudioSession() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .default, options: [])
            } catch {
                logger.error("Failed to configure audio session: \(error)")
            }
        #endif // os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    }

    /// Activate the audio session when playback begins.
    private func activateAudioSession() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                logger.error("Failed to activate audio session: \(error)")
            }
        #endif // os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    }

    /// Deactivate the audio session when playback stops.
    private func deactivateAudioSession() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.error("Failed to deactivate audio session: \(error)")
            }
        #endif // os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Use togglePlayPauseCommand as the primary transport control. This avoids
        // the system heuristics around separate play/pause commands getting out
        // of sync with our actual playback state.
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            smartPlayPause()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            nextTrack()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            previousTrack()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            seek(to: event.positionTime)
            return .success
        }

        // Start with commands disabled - they'll be enabled when playback starts
        disableRemoteCommandCenter()
    }

    /// Force the system Now Playing center to reflect our current play/pause state.
    /// This supplements the core's own Now Playing updates in case of timing issues.
    private func syncNowPlayingPlaybackRate() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func enableRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }

    private func disableRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }
}
