import AVFoundation
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

/// Parity E: the transport answers the PiP window's delegate callbacks map onto.
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

    @Test("an idle engine reports paused and an indefinite range, and play/pause map onto its transport")
    func idleEngine() throws {
        let engine = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        #expect(source.isPaused)
        #expect(source.timeRange().start == .negativeInfinity)
        source.setPlaying(false)
        #expect(source.isPaused)
        source.setPlaying(true)
        #expect(source.isPaused == (engine.state != .playing))
    }

    @Test("a released engine degrades to paused and indefinite instead of crashing")
    func releasedEngine() throws {
        var engine: AetherEngine? = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine!)
        engine = nil
        #expect(source.isPaused)
        #expect(source.timeRange().duration == .positiveInfinity)
        source.setPlaying(true)
        source.skip(by: 10)
    }

    #if canImport(AVKit) && !os(watchOS)
    @Test("the playback delegate is created once and survives as long as the source")
    func delegateIsRetained() throws {
        let engine = try AetherEngine()
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)
        #expect(source.playbackDelegate === source.playbackDelegate)
    }
    #endif
}
