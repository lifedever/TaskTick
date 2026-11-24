import AppKit
import SwiftUI

extension View {
    /// Gives a `Form(.grouped)` inside a sizing `TabView` a height floor, so the
    /// tab opens tall enough that its scroll view has nothing left to scroll —
    /// and a ceiling, so a tab taller than the display scrolls instead of
    /// pushing the window off screen.
    ///
    /// Both the Settings and the Task Editor windows are a `TabView` of grouped
    /// forms sized by `.fixedSize(vertical:)` → `.windowResizability(.contentSize)`
    /// (the editor through `resizable`, see below).
    /// `Form(.grouped)` wraps its rows in a ScrollView, and on macOS 26+ the
    /// ideal height that scroll view reports back up the chain lands roughly
    /// 20pt short of the rows it actually contains. The window therefore opens
    /// ~20pt too small and the form stays permanently scrollable by that much —
    /// invisible at rest, because macOS overlay scrollers only draw while
    /// scrolling, but a stray two-finger swipe makes the scroller appear and
    /// the content twitch.
    ///
    /// `minHeight` lands *before* `fixedSize`, so the ideal height the chain
    /// measures becomes `max(minHeight, form's own ideal)` and the form is
    /// actually laid out at that height — which is what makes the scroll view's
    /// viewport grow. Adding padding or a safe-area inset instead does not work:
    /// those grow the container around the form while the form itself stays
    /// pinned to its short ideal, and the scroller survives.
    ///
    /// Values are per-tab and measured, in the same spirit as
    /// `SettingsView.windowWidth`: each one is that tab's content height as laid
    /// out on screen plus ~40pt of headroom, enough to absorb both the ideal-height
    /// shortfall and the modest reflow between `en` and `zh-Hans`.
    ///
    /// The same mechanism has no natural upper bound: the form is laid out at
    /// its full content height, so it never scrolls, and the window grows with
    /// it. A schedule tab with a cron editor, a notification tab listing every
    /// push channel, or simply a small display made the window taller than the
    /// screen — its bottom, Save button included, ran off the display with
    /// nothing left to scroll (issue #55). `maxHeight` caps the form at what the
    /// window's screen can show, and past that the form scrolls as usual.
    ///
    /// `resizable` lets the tab be laid out shorter than its content — the form
    /// scrolls — while still reporting its content height as the ideal. On its
    /// own that does nothing; the `TabView` holding such tabs applies
    /// `resizableToTabContent(defaultHeight:)` to turn it into a window that
    /// fits short tabs exactly and lets tall ones be dragged.
    func groupedFormSizing(minHeight: CGFloat, resizable: Bool = false) -> some View {
        modifier(GroupedFormSizing(minHeight: minHeight, resizable: resizable))
    }

    /// For a `TabView` whose tabs use `groupedFormSizing(minHeight:resizable: true)`.
    /// A tab whose content fits in `defaultHeight` locks the window to that
    /// content height, exactly as `fixedSize` did — switching tabs still snaps
    /// the window to each one. A taller tab opens at `defaultHeight` and can be
    /// dragged up to its full content height (or the screen), and back down.
    func resizableToTabContent(defaultHeight: CGFloat) -> some View {
        TabContentRange(defaultHeight: defaultHeight) { self }
    }
}

private struct GroupedFormSizing: ViewModifier {
    let minHeight: CGFloat
    let resizable: Bool

    /// Visible height of the screen the window is on. Seeded from the main
    /// screen so the very first layout is already capped, then replaced by the
    /// window's own screen once the form is in a window.
    @State private var screenHeight = NSScreen.main?.visibleFrame.height ?? 800

    /// Everything a window stacks around the form: title bar, tab bar, and the
    /// editor's Cancel/Save bar. Measured at 119pt on the Task Editor (the
    /// taller of the two windows, macOS 27); the extra is headroom for title
    /// bar and control heights that differ between macOS releases. Settings has
    /// no button bar, so there it only stops a little short of the screen edge.
    private static let windowChrome: CGFloat = 140

    /// Below this the form would be too cramped to use; a display that small
    /// gets a window that overflows rather than one with a sliver of content.
    private static let smallestCap: CGFloat = 240

    func body(content: Content) -> some View {
        let cap = max(Self.smallestCap, screenHeight - Self.windowChrome)
        sized(content, cap: cap)
            .scrollBounceBehavior(.basedOnSize)
            .background(ScreenFitting { height in
                if height != screenHeight { screenHeight = height }
            })
    }

    @ViewBuilder
    private func sized(_ content: Content, cap: CGFloat) -> some View {
        if resizable {
            ShrinkableFormHeight(floor: minHeight, shortest: Self.smallestCap, cap: cap) {
                content
            }
        } else {
            content
                // min is clamped to the cap: a floor above the ceiling is a
                // contradictory frame, and the ceiling is the one that matters.
                .frame(minHeight: min(minHeight, cap), maxHeight: cap)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A form that reports its content height as its ideal but accepts any height
/// down to `shortest`, scrolling below its content.
///
/// The content height is `max(floor, form's ideal)` — the value `fixedSize`
/// would lock it to, `floor` covering the ~20pt the grouped form's ideal comes
/// up short — capped at the screen.
private struct ShrinkableFormHeight: Layout {
    let floor: CGFloat
    let shortest: CGFloat
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let form = subviews.first else { return .zero }
        let width = proposal.width ?? form.sizeThatFits(.unspecified).width
        let natural = min(cap, max(floor, form.sizeThatFits(ProposedViewSize(width: width, height: nil)).height))
        let lower = min(natural, shortest)
        let height = proposal.height.map { min(max($0, lower), natural) } ?? natural
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Turns the selected tab's content height into the window's limits.
///
/// A `.contentSize` window takes its minimum from proposing zero and its
/// maximum from proposing infinity; `TabView` forwards the tab's minimum and
/// ideal but answers infinity with infinity. So the maximum is the `TabView`'s
/// ideal (its tab's content height plus its own chrome), and the minimum and
/// opening height are that, capped at `defaultHeight` — but never under what
/// the `TabView` can be squeezed to.
private struct TabContentRange: Layout {
    let defaultHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let tabs = subviews.first else { return .zero }
        let width = proposal.width ?? tabs.sizeThatFits(.unspecified).width
        let squeezed = tabs.sizeThatFits(ProposedViewSize(width: width, height: 0)).height
        let upper = max(squeezed, tabs.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        let lower = min(upper, max(squeezed, defaultHeight))
        let height = proposal.height.map { min(max($0, lower), upper) } ?? lower
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Reports the visible height of the window's screen and keeps the window
/// inside it.
///
/// Capping the form isn't enough on its own: a content-sized window grows
/// downward from its top edge, so a window the user had dragged low on the
/// screen still ran its bottom off the display when a taller tab was selected.
private struct ScreenFitting: NSViewRepresentable {
    let onScreenHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScreenFittingView {
        let view = ScreenFittingView()
        view.onScreenHeight = onScreenHeight
        return view
    }

    func updateNSView(_ view: ScreenFittingView, context: Context) {
        view.onScreenHeight = onScreenHeight
    }
}

private final class ScreenFittingView: NSView {
    var onScreenHeight: (CGFloat) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowDidResize),
                           name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(screenDidChange),
                           name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(screenDidChange),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        reportScreenHeight()
    }

    @objc private func windowDidResize(_ note: Notification) {
        keepWindowOnScreen()
    }

    @objc private func screenDidChange(_ note: Notification) {
        reportScreenHeight()
        keepWindowOnScreen()
    }

    private func reportScreenHeight() {
        guard let height = window?.screen?.visibleFrame.height else { return }
        // Deferred: this can run inside a SwiftUI view update, where writing
        // the modifier's state directly is not allowed.
        DispatchQueue.main.async { [weak self] in
            self?.onScreenHeight(height)
        }
    }

    private func keepWindowOnScreen() {
        guard let window, let visible = window.screen?.visibleFrame else { return }
        let frame = window.frame
        guard frame.minY < visible.minY else { return }
        // Slide up just far enough to bring the bottom back, but never push the
        // title bar above the top — if the window is somehow still taller than
        // the screen, keeping it draggable matters more.
        let y = min(visible.minY, visible.maxY - frame.height)
        window.setFrameOrigin(NSPoint(x: frame.minX, y: y))
    }
}
