import AVFoundation
#if canImport(AVKit) && os(macOS)
@preconcurrency import AVKit
#endif
import Testing
import CoreMedia
@testable import AetherEngine

/// SW-PiP Phase A: the sample-buffer PiP UI needs the playable range on the PTS axis of the
/// enqueued frames, which is the SOURCE axis (sourceTime = currentTime + source offset).
@Suite("Software PiP time range")
struct SoftwarePiPSourceTests {
    @Test("VOD zero-based source: range starts at 0 for the full duration")
    func vodZeroBased() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, sourceTime: 12.0, currentTime: 12.0, duration: 3600)
        #expect(abs(r.start.seconds - 0) < 0.001)
        #expect(abs(r.duration.seconds - 3600) < 0.001)
    }

    @Test("VOD with source offset: range starts at the container start PTS")
    func vodWithOffset() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, sourceTime: 152.5, currentTime: 2.5, duration: 600)
        #expect(abs(r.start.seconds - 150.0) < 0.001)
        #expect(abs(r.duration.seconds - 600) < 0.001)
    }

    @Test("live: indefinite range")
    func liveIndefinite() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: true, sourceTime: 500, currentTime: 100, duration: 0)
        #expect(r.start == .negativeInfinity)
        #expect(r.duration == .positiveInfinity)
    }

    @Test("unknown duration falls back to indefinite")
    func unknownDurationIndefinite() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, sourceTime: 5, currentTime: 5, duration: 0)
        #expect(r.start == .negativeInfinity)
    }
}

/// The transport answers the PiP window's delegate callbacks map onto.
@Suite("Software PiP transport mapping")
@MainActor
struct SoftwarePiPTransportTests {
    @Test("no software session: no PiP source to offer")
    func noSessionNoSource() throws {
        let engine = try AetherEngine()
        #expect(engine.softwarePiPSource == nil)
    }

    @Test("skip target is relative, floored at 0, capped at the VOD duration")
    func skipTargets() {
        #expect(SoftwarePiPSource.skipTarget(isLive: false, currentTime: 100, duration: 600, by: 15) == 115)
        #expect(SoftwarePiPSource.skipTarget(isLive: false, currentTime: 100, duration: 600, by: -15) == 85)
        #expect(SoftwarePiPSource.skipTarget(isLive: false, currentTime: 5, duration: 600, by: -15) == 0)
        #expect(SoftwarePiPSource.skipTarget(isLive: false, currentTime: 595, duration: 600, by: 15) == 600)
    }

    @Test("live and unknown-duration sources are not capped")
    func skipTargetsUncapped() {
        #expect(SoftwarePiPSource.skipTarget(isLive: true, currentTime: 100, duration: 50, by: 15) == 115)
        #expect(SoftwarePiPSource.skipTarget(isLive: false, currentTime: 100, duration: 0, by: 15) == 115)
    }

    @Test("an idle engine reports paused with an indefinite range, and pause keeps it paused")
    func idleEngine() throws {
        let engine = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        #expect(source.isPaused)
        #expect(source.timeRange().start == .negativeInfinity)
        source.setPlaying(false)
        #expect(source.isPaused)
        #expect(engine.state != .playing)
    }

    @Test("a released engine has no content: paused and an invalid range")
    func releasedEngine() async throws {
        var engine: AetherEngine? = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine!)
        engine = nil
        #expect(source.isPaused)
        #expect(!source.timeRange().isValid)
        source.setPlaying(true)
        await source.skipAndWait(by: 10)
    }

    @Test("skipAndWait on an idle engine returns")
    func skipAwaitsIdle() async throws {
        let engine = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        await source.skipAndWait(by: 10)
        #expect(source.isPaused)
    }

    #if canImport(AVKit) && !os(watchOS) && os(macOS)
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Evaluated off the main actor by the trait, so it asks AVKit directly.
    nonisolated static let pipSupported = AVPictureInPictureController.isPictureInPictureSupported()

    @Test("delegate callbacks through a real controller: skip completes once, no content is invalid",
          .enabled(if: SoftwarePiPTransportTests.pipSupported, "PiP is not supported on this host"))
    func delegateThroughController() async throws {
        let engine = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        let controller = try #require(source.makePictureInPictureController())
        let delegate = source.playbackDelegate
        #expect(delegate.pictureInPictureControllerIsPlaybackPaused(controller))
        #expect(delegate.pictureInPictureControllerTimeRangeForPlayback(controller).start == .negativeInfinity)

        let done = Counter()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            delegate.pictureInPictureController(controller, skipByInterval: CMTime(seconds: 10, preferredTimescale: 600)) {
                done.bump()
                c.resume()
            }
        }
        // NaN interval: completes immediately, still exactly once.
        delegate.pictureInPictureController(controller, skipByInterval: .invalid) { done.bump() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(done.value == 2)

        let orphan = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: try AetherEngine())
        let orphanController = try #require(orphan.makePictureInPictureController())
        let orphanDelegate = orphan.playbackDelegate
        // Engine of `orphan` is released once the temporary above is gone.
        #expect(orphanDelegate.pictureInPictureControllerIsPlaybackPaused(orphanController))
        #expect(!orphanDelegate.pictureInPictureControllerTimeRangeForPlayback(orphanController).isValid)
    }

    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (paused: Bool, range: CMTimeRange)?
        func set(paused: Bool, range: CMTimeRange) { lock.lock(); stored = (paused, range); lock.unlock() }
        var value: (paused: Bool, range: CMTimeRange)? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @Test("delegate getters answer from a background queue while the main thread is busy",
          .enabled(if: SoftwarePiPTransportTests.pipSupported, "PiP is not supported on this host"))
    func gettersOffMainDoNotBlock() throws {
        let engine = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        let controller = try #require(source.makePictureInPictureController())
        let delegate = source.playbackDelegate

        let answers = Answers()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            delegate.pictureInPictureController(controller, setPlaying: false)
            answers.set(
                paused: delegate.pictureInPictureControllerIsPlaybackPaused(controller),
                range: delegate.pictureInPictureControllerTimeRangeForPlayback(controller))
            finished.signal()
        }
        // This test runs on the main thread and holds it here: a getter that waited on main would
        // never finish inside the budget.
        let outcome = finished.wait(timeout: .now() + 5)
        #expect(outcome == .success)
        let result = try #require(answers.value)
        #expect(result.paused)
        #expect(result.range.start == .negativeInfinity)
    }

    @Test("the snapshot refreshes from state and duration changes without the controller helper")
    func snapshotRefreshesWithoutController() async throws {
        let engine = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        engine.state = .paused
        engine.duration = 600
        await Task.yield()
        await Task.yield()
        let snap = source.snapshot.withLock { $0 }
        #expect(snap.isPaused)
        #expect(abs(snap.range.duration.seconds - 600) < 0.001)
    }

    @Test("the PiP fit sizes the display layer to the picture's aspect and restores on exit")
    @MainActor
    func pictureFitFollowsPictureInPicture() throws {
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 640, height: 392))
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        view.attach(layer)
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 640, height: 392))
        view.setPictureFit(CGSize(width: 1280, height: 720))
        let aspect = layer.frame.width / layer.frame.height
        #expect(abs(aspect - 16.0 / 9.0) < 0.001)
        #expect(layer.frame.width <= 640.001 && layer.frame.height <= 392.001)
        view.setPictureFit(nil)
        #expect(layer.frame == CGRect(x: 0, y: 0, width: 640, height: 392))
    }

    @Test("the aspect-fit rectangle is centred and never exceeds the bounds")
    func fittedRect() {
        let r = AetherPlayerView.hostedFrame(in: CGRect(x: 0, y: 0, width: 1200, height: 700), fitting: CGSize(width: 1920, height: 1080))
        #expect(abs(r.width - 1200) < 0.001 && abs(r.height - 675) < 0.001)
        #expect(abs(r.midX - 600) < 0.001 && abs(r.midY - 350) < 0.001)
        #expect(AetherPlayerView.hostedFrame(in: CGRect(x: 0, y: 0, width: 10, height: 10), fitting: nil) == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("ending the session resets pictureInPictureActive and clears the source")
    @MainActor
    func stopResetsPictureInPictureFlag() throws {
        let engine = try AetherEngine()
        engine.softwarePiPSource = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        engine.pictureInPictureActive = true
        engine.stopInternal()
        #expect(engine.softwarePiPSource == nil)
        #expect(!engine.pictureInPictureActive)
    }

    @Test("state and duration changes invalidate quietly, and a released source is not retained",
          .enabled(if: SoftwarePiPTransportTests.pipSupported, "PiP is not supported on this host"))
    func invalidationPathReleases() async throws {
        let engine = try AetherEngine()
        weak var weakSource: SoftwarePiPSource?
        do {
            var source: SoftwarePiPSource? = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
            weakSource = source
            var controller = try #require(source?.makePictureInPictureController())
            engine.state = .paused
            engine.duration = 600
            await Task.yield()
            await Task.yield()
            // Read the sink-refreshed snapshot directly: the main getters would refresh it live.
            let snap = try #require(source).snapshot.withLock { $0 }
            #expect(snap.isPaused)
            #expect(abs(snap.range.duration.seconds - 600) < 0.001)
            _ = controller
            controller = try #require(source?.makePictureInPictureController())
            _ = controller
            source = nil
        }
        engine.state = .playing
        engine.duration = 700
        await Task.yield()
        await Task.yield()
        #expect(weakSource == nil)
    }
    #endif
}
