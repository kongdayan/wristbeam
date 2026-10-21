import SwiftUI
import AppKit

/// Read the enclosing native scroll view so list and detail offsets stay independent.
struct ScrollPositionKeeper: NSViewRepresentable {
    let positions: ScrollPositions
    let key: String
    func makeNSView(context: Context) -> Probe { Probe(positions: positions, key: key) }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        let positions: ScrollPositions
        let key: String
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        var ready = false
        var stopped = false
        init(positions: ScrollPositions, key: String) { self.positions = positions; self.key = key; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        func attach() {
            guard !stopped, scroll == nil, let scroll = enclosingScrollView else { return }
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            DispatchQueue.main.async { [weak self, weak scroll] in
                guard let self, let scroll, !self.stopped else { return }
                scroll.window?.contentView?.layoutSubtreeIfNeeded()
                let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                let y = min(maxY, max(0, self.positions.offsets[self.key] ?? 0))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                self.ready = true
                self.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.save() }
                }
            }
        }
        func save() {
            guard ready, !stopped, let scroll else { return }
            positions.offsets[key] = max(0, scroll.contentView.bounds.origin.y)
        }
        func stop() {
            // Bounds notifications saved the user's offset; a teardown layout may now be zero.
            stopped = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
