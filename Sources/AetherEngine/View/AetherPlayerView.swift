import Foundation
import QuartzCore
import AVFoundation

#if canImport(UIKit)
import UIKit
import SwiftUI
#elseif canImport(AppKit)
import AppKit
import SwiftUI
#endif

/// A single render surface owned by AetherEngine.
///
/// The host embeds one instance (UIKit on iOS/tvOS, AppKit on macOS) and
/// hands it to `engine.bind(view:)`. The engine then attaches whichever
/// `CALayer` is active for the current source:
///
/// - `AVPlayerLayer` for the native AVPlayer path (HEVC, H.264, plus AV1
///   on devices with hardware AV1 decode).
/// - `AVSampleBufferDisplayLayer` for the software path driven by
///   `SoftwarePlaybackHost` (AV1 without hardware decode, VP9, MPEG-4
///   Part 2, MPEG-2, VC-1).
///
/// The view swaps the hosted layer internally on dispatch changes, so the
/// host never needs to know which backend is rendering. The active layer
/// can also change across sessions when consecutive sources dispatch to
/// different paths.
@MainActor
public final class AetherPlayerView: PlatformBaseView, HeldStillSurface {

    private var hostedLayer: CALayer?
    /// AE#711 follow-up: the picture held over an in-place item swap, above `hostedLayer`.
    private let presenter = HeldStillPresenter()
    private var stillLayer: CALayer? { presenter.layer }

    /// Engine-internal. The engine this view was last bound to, so a dismantling surface can unbind
    /// from it synchronously and a second engine binding the view can take it over (AE#536).
    weak var bindingEngine: AetherEngine?

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    #endif

    private func commonInit() {
        #if canImport(UIKit)
        backgroundColor = .black
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = CGColor.black
        #endif
    }

    // MARK: - Layout

    #if canImport(UIKit)
    public override func layoutSubviews() {
        super.layoutSubviews()
        applyLayerFrame()
    }
    #elseif canImport(AppKit)
    public override func layout() {
        super.layout()
        applyLayerFrame()
    }
    #endif

    /// The picture's size while picture in picture is active (nil otherwise). A system PiP window
    /// mirrors the display layer's own geometry, so a layer sized to this view carries the view's aspect
    /// into the window as offset or clipped video. While set, the software display layer is sized to
    /// the picture's aspect-fit rectangle instead, which is where `resizeAspect` draws it anyway, so
    /// this view looks the same and the window gets a layer of the picture's shape.
    private var pictureFit: CGSize?

    /// Engine-internal. Size the hosted software layer to the picture's shape (`size` non-nil, PiP
    /// active) or back to the full view (nil). No-op for a layer that is not a resize-aspect sample
    /// buffer layer.
    func setPictureFit(_ size: CGSize?) {
        guard pictureFit != size else { return }
        pictureFit = size
        #if canImport(AppKit)
        // Flexible sizing would otherwise stretch the layer back to the full view during a live drag.
        hostedLayer?.autoresizingMask = size == nil ? [.layerWidthSizable, .layerHeightSizable] : []
        #endif
        applyLayerFrame()
    }

    /// Frame for the hosted layer inside `bounds`: the aspect-fit rectangle of `content` when given,
    /// else the full bounds.
    nonisolated static func hostedFrame(in bounds: CGRect, fitting content: CGSize?) -> CGRect {
        guard let content, content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var hostedFrame: CGRect {
        guard let sample = hostedLayer as? AVSampleBufferDisplayLayer, sample.videoGravity == .resizeAspect else { return bounds }
        return Self.hostedFrame(in: bounds, fitting: pictureFit)
    }

    private func applyLayerFrame() {
        guard hostedLayer != nil || stillLayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = hostedFrame
        presenter.layout(bounds)
        CATransaction.commit()
    }

    // MARK: - Engine-only attachment

    /// Engine-internal. Replace whichever layer is currently hosted with
    /// `layer`. Synchronous, runs on the main actor, no implicit
    /// animations so swaps don't flash. Idempotent if the same layer is
    /// already attached. A previously hosted layer is removed only while it
    /// still sits in this view: a layer an engine has since presented on
    /// another surface is not pulled back out of it (AE#536).
    func attach(_ layer: CALayer) {
        if hostedLayer === layer { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let hosted = hostedLayer, hosted.superlayer === self.layer {
            hosted.removeFromSuperlayer()
        }
        #if canImport(UIKit)
        if let still = stillLayer { self.layer.insertSublayer(layer, below: still) } else { self.layer.addSublayer(layer) }
        #elseif canImport(AppKit)
        if let still = stillLayer { self.layer?.insertSublayer(layer, below: still) } else { self.layer?.addSublayer(layer) }
        // Resize the video layer in lockstep with the view's bounds during a
        // live window drag. Without this it only catches up on the next layout()
        // pass, and because an NSView's layer is anchored bottom-left that lag
        // reads as the image sliding off-center while resizing. Starting at full
        // bounds with both axes flexible keeps it full-bounds throughout.
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        #endif
        hostedLayer = layer
        #if canImport(AppKit)
        if pictureFit != nil { layer.autoresizingMask = [] }
        #endif
        layer.frame = hostedFrame
        CATransaction.commit()
    }

    /// Engine-internal. Remove the current hosted layer without
    /// replacement (used on unbind / teardown). Same ownership rule as
    /// `attach`: a layer that has moved to another surface stays there.
    func detach() {
        clearStill()
        guard let hosted = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hosted.superlayer === self.layer {
            hosted.removeFromSuperlayer()
        }
        hostedLayer = nil
        CATransaction.commit()
    }

    // MARK: - Held picture

    /// Engine-internal. Lays `frame` over the hosted layer until `clearStill()`, see `HeldStillPresenter`.
    @discardableResult
    func showStill(_ frame: CVPixelBuffer, gravity: AVLayerVideoGravity, isHDR: Bool) -> Bool {
        let host: CALayer? = layer
        return presenter.show(frame, gravity: gravity, isHDR: isHDR, on: host, bounds: bounds)
    }

    /// Engine-internal. Removes the held picture, if any. Idempotent.
    func clearStill() { presenter.clear() }

    var isHoldingStill: Bool { presenter.layer != nil }
}

// MARK: - Platform base view alias

#if canImport(UIKit)
public typealias PlatformBaseView = UIView
#elseif canImport(AppKit)
public typealias PlatformBaseView = NSView
#endif

// MARK: - SwiftUI wrapper

#if canImport(UIKit)
/// SwiftUI surface for embedding AetherEngine playback.
///
/// ```swift
/// AetherPlayerSurface(engine: engine)
///     .ignoresSafeArea()
/// ```
public struct AetherPlayerSurface: UIViewRepresentable {
    private let engine: AetherEngine

    public init(engine: AetherEngine) {
        self.engine = engine
    }

    public func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    public func updateUIView(_ uiView: AetherPlayerView, context: Context) {
        // #188: when a host swaps its AetherEngine instance at the same structural
        // position, SwiftUI reuses this platform view and only calls updateUIView,
        // so the new engine's bind(view:) never runs from makeUIView. Rebinding here
        // points the new engine at the reused view and re-attaches its layer; bind is
        // idempotent for the steady-state existing === view case, so this is cheap.
        engine.bind(view: uiView)
    }

    public static func dismantleUIView(_ uiView: AetherPlayerView, coordinator: ()) {
        // AE#536: unbind now, not in a later Task. A surface remounted by identity
        // is dismantled after the incoming one was bound, and SwiftUI may have
        // rebound the outgoing view on its way out; unbinding it here hands the
        // layer back to the incoming view at once. Identity-guarded, so it never
        // detaches a successor.
        MainActor.assumeIsolated {
            uiView.bindingEngine?.unbind(view: uiView)
        }
    }
}
#elseif canImport(AppKit)
public struct AetherPlayerSurface: NSViewRepresentable {
    private let engine: AetherEngine

    public init(engine: AetherEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    public func updateNSView(_ nsView: AetherPlayerView, context: Context) {
        // #188: rebind on update so an engine swap at the same structural position
        // takes over the reused view. Idempotent for the steady-state case.
        engine.bind(view: nsView)
    }

    public static func dismantleNSView(_ nsView: AetherPlayerView, coordinator: ()) {
        // AE#536: unbind synchronously so the layer moves to a surface bound
        // after this one instead of waiting for the next session.
        MainActor.assumeIsolated {
            nsView.bindingEngine?.unbind(view: nsView)
        }
    }
}
#endif
