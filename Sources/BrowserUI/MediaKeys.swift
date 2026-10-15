import Foundation
import MediaPlayer
import BrowserCore

/// The keyboard's play/pause, previous and next keys, the headphones' buttons and Control Center's "now playing" tile, for what the page plays.
/// Only one window's card is "the" player at a time: the window that shows its card attaches itself here, and detaches when it hides it.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    enum Action: Equatable { case play, pause, toggle, skip(Double), seek(Double) }

    /// What to do when a key is pressed (set while a card is shown).
    private var handler: ((Action) -> Void)?
    private var registered = false

    /// A card is shown: make Orée the app the keys talk to, and describe what plays.
    func update(_ info: MediaInfo, host: String, handler: @escaping (Action) -> Void) {
        self.handler = handler
        registerOnce()
        let center = MPNowPlayingInfoCenter.default()
        var details: [String: Any] = [
            MPMediaItemPropertyTitle: info.title.isEmpty ? host : info.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.position,
            MPNowPlayingInfoPropertyPlaybackRate: info.paused ? 0 : info.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1,
        ]
        if !info.artist.isEmpty { details[MPMediaItemPropertyArtist] = info.artist }
        if !info.isLive { details[MPMediaItemPropertyPlaybackDuration] = info.duration }
        center.nowPlayingInfo = details
        center.playbackState = info.paused ? .paused : .playing
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.isEnabled = !info.isLive
        commands.skipForwardCommand.isEnabled = !info.isLive
        commands.changePlaybackPositionCommand.isEnabled = !info.isLive
    }

    /// The card is gone: the keys go back to whatever played before.
    func clear() {
        handler = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// Runs what a key would (the keys themselves cannot be pressed in a test).
    func perform(_ action: Action) { handler?(action) }

    private func registerOnce() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @Sendable (MPRemoteCommandEvent) -> Action?) {
            command.isEnabled = true
            command.addTarget { event in
                guard let action = action(event) else { return .commandFailed }
                DispatchQueue.main.async { MainActor.assumeIsolated { MediaKeys.shared.perform(action) } }
                return .success
            }
        }
        bind(commands.playCommand) { _ in .play }
        bind(commands.pauseCommand) { _ in .pause }
        bind(commands.togglePlayPauseCommand) { _ in .toggle }
        // Previous / next: the page's own "previous track" is out of reach, so they jump 15 s like the skip buttons do.
        bind(commands.nextTrackCommand) { _ in .skip(15) }
        bind(commands.previousTrackCommand) { _ in .skip(-15) }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        bind(commands.skipForwardCommand) { event in .skip((event as? MPSkipIntervalCommandEvent)?.interval ?? 15) }
        bind(commands.skipBackwardCommand) { event in .skip(-((event as? MPSkipIntervalCommandEvent)?.interval ?? 15)) }
        bind(commands.changePlaybackPositionCommand) { event in (event as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) } }
    }
}
