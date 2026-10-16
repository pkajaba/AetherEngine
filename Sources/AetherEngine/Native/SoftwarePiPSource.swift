import AVFoundation
import CoreMedia
#if canImport(AVKit)
import AVKit
#endif

/// SW-PiP bridge (Sodalite SW-PiP Phase A): everything a host needs to build an
/// AVPictureInPictureController ContentSource around the software path, WITHOUT AVKit entering the
/// engine. The analog of `currentAVPlayer` for sample-buffer PiP: the layer plus the four transport
/// answers backing AVPictureInPictureSampleBufferPlaybackDelegate. Time answers live here because
/// the enqueued frames' PTS axis (source axis, synchronizer clock) is engine knowledge.
@MainActor
public final class SoftwarePiPSource {
    public let layer: AVSampleBufferDisplayLayer
    let isLive: Bool
    private weak var engine: AetherEngine?

    init(layer: AVSampleBufferDisplayLayer, isLive: Bool, engine: AetherEngine) {
        self.layer = layer
        self.isLive = isLive
        self.engine = engine
    }

    /// Playable range on the enqueued frames' PTS axis (source axis). Live sources report an
    /// indefinite range so the window shows live UI.
    public func timeRange() -> CMTimeRange {
        guard let engine else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return AetherEngine.softwarePiPTimeRange(
            isLive: isLive,
            sourceTime: engine.sourceTime,
            currentTime: engine.currentTime,
            duration: engine.duration
        )
    }

    public var isPaused: Bool { engine?.state != .playing }

    public func setPlaying(_ playing: Bool) {
        if playing { engine?.play() } else { engine?.pause() }
    }

    public func skip(by seconds: Double) {
        Task { await skipAndWait(by: seconds) }
    }

    /// The seek target for a PiP skip button: relative to the playhead, never before 0, and on a
    /// finite VOD never past the end. Live sources have no end to clamp to.
    nonisolated static func skipTarget(isLive: Bool, currentTime: Double, duration: Double, by seconds: Double) -> Double {
        let target = max(0, currentTime + seconds)
        guard !isLive, duration.isFinite, duration > 0 else { return target }
        return min(target, duration)
    }

    /// `skip(by:)` that returns once the seek has settled, for the PiP skip completion handler.
    func skipAndWait(by seconds: Double) async {
        guard let engine else { return }
        let target = Self.skipTarget(isLive: isLive, currentTime: engine.currentTime, duration: engine.duration, by: seconds)
        await engine.seek(to: target)
    }

    #if canImport(AVKit) && !os(watchOS)
    /// The playback delegate that maps the PiP window's play, pause, skip and time-range queries onto
    /// this source. Held here because `ContentSource` does not keep its delegate alive.
    public private(set) lazy var playbackDelegate = SoftwarePiPPlaybackDelegate(source: self)

    /// True when the system offers PiP at all and this session has a layer to present.
    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// A ready `AVPictureInPictureController` for this session's display layer, or nil when PiP is
    /// not supported on this device. The host keeps the controller, sets its delegate and calls
    /// `startPictureInPicture()`; it must also set `AetherEngine.pictureInPictureActive` from the
    /// controller's will-start / did-stop callbacks. tvOS AVKit accepts the source but does not
    /// present sample-buffer content (README, Picture in Picture).
    public func makePictureInPictureController() -> AVPictureInPictureController? {
        guard Self.isSupported else { return nil }
        let content = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: playbackDelegate)
        return AVPictureInPictureController(contentSource: content)
    }
    #endif
}

#if canImport(AVKit) && !os(watchOS)
/// `AVPictureInPictureSampleBufferPlaybackDelegate` over a `SoftwarePiPSource`. AVKit calls these on
/// the main thread.
public final class SoftwarePiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    private weak var source: SoftwarePiPSource?

    init(source: SoftwarePiPSource) {
        self.source = source
    }

    public func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { source?.setPlaying(playing) }
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            source?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { source?.isPaused ?? true }
    }

    public func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    public func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) {
        let seconds = skipInterval.seconds
        Task { @MainActor [weak source] in
            await source?.skipAndWait(by: seconds)
            completionHandler()
        }
    }
}
#endif
