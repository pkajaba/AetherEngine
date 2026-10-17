#if os(macOS)
import AppKit

/// Follows the size of the system picture in picture window on macOS while a software session is in
/// it, so the display layer can be laid out to the visible picture area (AE#810).
///
/// AVKit gives no public size for that window, so it is found with public AppKit only: the visible
/// panel in `NSApp.windows` that did not exist when the PiP controller was made (it is already there by
/// the time a host reports PiP active). Its content view posts the public frame
/// change notification, which fires when the window first settles, on every resize and when PiP
/// stops. `refresh()` is a second trigger, for the render-size delegate callback.
@MainActor
final class PictureInPictureAreaTracker {
    private let onChange: (CGSize?) -> Void
    private var knownWindows: Set<ObjectIdentifier> = []
    private weak var contentView: NSView?
    private var postedBefore = false
    private var observers: [NSObjectProtocol] = []
    private var isTracking = false
    private weak var hostWindow: NSWindow?

    init(onChange: @escaping (CGSize?) -> Void) {
        self.onChange = onChange
    }

    /// Begin looking for the PiP window. `known` are the windows that existed before the controller was
    /// made (empty when unknown: any visible panel then qualifies); `host` is the window of the view
    /// showing the video and is never taken for it. Idempotent.
    func start(known: Set<ObjectIdentifier>, host: NSWindow?) {
        guard !isTracking else { return }
        isTracking = true
        knownWindows = known
        hostWindow = host
        // Cheap and public: posted for every window update, so the window is picked up as soon as it
        // exists. Ignored once found.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    /// Stop following, give the content view back its notification setting and report no area.
    func stop() {
        guard isTracking else { return }
        isTracking = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        contentView?.postsFrameChangedNotifications = postedBefore
        contentView = nil
        knownWindows.removeAll()
        hostWindow = nil
        onChange(nil)
    }

    /// Find the window if it is not found yet, then report its content size.
    func refresh() {
        guard isTracking else { return }
        if contentView == nil { adoptWindow() }
        if let view = contentView { report(view.bounds.size) }
    }

    private func adoptWindow() {
        guard let window = NSApp.windows.first(where: {
            !knownWindows.contains(ObjectIdentifier($0)) && $0 !== hostWindow
                && $0 is NSPanel && $0.isVisible && $0.contentView != nil
        }), let view = window.contentView else { return }
        contentView = view
        postedBefore = view.postsFrameChangedNotifications
        view.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    private func report(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        onChange(size)
    }
}
#endif
