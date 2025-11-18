//
//  Playable.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import Foundation

/// Protocol that defines the requirements for any media item that can be played
/// by the media manager.
///
/// Types conforming to this protocol can be used with `PlayerEngine` for playback,
/// caching, playlist management, and lock screen integration.
///
/// Note: This protocol does not require Sendable conformance, allowing it to work
/// with SwiftData PersistentModels. PlayerEngine handles concurrency by capturing
/// only Sendable properties (like id) in async contexts.
public protocol Playable: Identifiable, Hashable {
    /// Unique identifier for the media item
    /// Used for caching, playlist management, and identifying the current track
    var id: Int { get }

    /// Title of the media item
    /// Displayed in player UI and lock screen controls
    var title: String { get }

    /// Artist or creator name
    /// Displayed in player UI and lock screen controls
    var artist: String { get }

    /// Duration of the media in seconds
    /// Used for progress tracking and time display
    var duration: TimeInterval { get }

    /// URL to the audio file
    /// Can be a remote URL for streaming or local file URL for cached playback
    var audioURL: URL? { get }
}
