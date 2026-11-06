#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif
import WebKit

/// Creates the platform view that shows a page: `ChallengeBrowserView` on the Dart side.
@MainActor
final class PageViewFactory: NSObject, @preconcurrency FlutterPlatformViewFactory {
  private let container: (Int64) -> PageContainer

  init(container: @escaping (Int64) -> PageContainer) {
    self.container = container
  }

  #if os(iOS)
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
      PageView(container(pageId(args)))
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
      FlutterStandardMessageCodec.sharedInstance()
    }
  #elseif os(macOS)
    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
      container(pageId(args))
    }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
      FlutterStandardMessageCodec.sharedInstance()
    }
  #endif

  private func pageId(_ args: Any?) -> Int64 {
    ((args as? [String: Any])?["pageId"] as? NSNumber)?.int64Value ?? -1
  }
}

#if os(iOS)
  private final class PageView: NSObject, FlutterPlatformView {
    private let container: PageContainer

    init(_ container: PageContainer) { self.container = container }

    func view() -> UIView { container }
  }
#endif

/// Where a shown page sits: the platform view's own view. It adopts the page's web view while it is
/// in a window and hands it back to the hidden host when it leaves, moves keyboard focus into the
/// page, and reports where focus leaves it.
final class PageContainer: NativeView {
  private weak var page: Page?
  private weak var host: NativeView?
  private let exit: (FocusDirection) -> Void

  init(page: Page?, host: NativeView?, exit: @escaping (FocusDirection) -> Void) {
    self.page = page
    self.host = host
    self.exit = exit
    super.init(frame: .zero)
    #if os(macOS)
      addSubview(before)
      addSubview(after)
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  /// Moves keyboard focus into the page: to its first control, or its last when going back.
  func enter(forward: Bool) {
    guard let webView = page?.webView, webView.superview === self else { return }
    #if os(iOS)
      _ = webView.becomeFirstResponder()
      webView.evaluateJavaScript(forward ? Self.focusFirst : Self.focusLast)
    #elseif os(macOS)
      // As if Tab reached the page: WebKit focuses its first control (its last going back), in
      // frames too.
      if forward {
        window?.selectKeyView(following: before)
      } else {
        window?.selectKeyView(preceding: after)
      }
    #endif
  }

  /// Takes keyboard focus out of the page, back to Flutter, if the page has it.
  func blur() {
    guard let webView = page?.webView else { return }
    #if os(iOS)
      webView.endEditing(true)
    #elseif os(macOS)
      if let focused = window?.firstResponder as? NSView, focused.isDescendant(of: webView) { returnKeys() }
    #endif
  }

  private func moved() {
    guard let page else { return }
    if window != nil {
      if page.webView.superview !== self { adopt(page) }
    } else if let host, page.webView.superview === self {
      page.webView.removeFromSuperview()
      #if os(macOS)
        page.webView.nextKeyView = nil
      #endif
      page.webView.frame = host.bounds
      host.addSubview(page.webView)
      page.container = nil
    }
  }

  private func adopt(_ page: Page) {
    let webView = page.webView
    webView.removeFromSuperview()
    webView.frame = bounds
    #if os(iOS)
      webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    #elseif os(macOS)
      webView.autoresizingMask = [.width, .height]
      before.nextKeyView = webView
      webView.nextKeyView = after
    #endif
    addSubview(webView)
    page.container = self
    if let forward = page.takePendingFocus() {
      // Once the window has laid the page out.
      DispatchQueue.main.async { [weak self] in self?.enter(forward: forward) }
    }
  }

  #if os(iOS)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      moved()
    }

    /// The document's own controls. Not frames: focusing a frame element reaches none of its controls.
    private static let focusable = "a[href],button,input,select,textarea,[tabindex]:not([tabindex=\"-1\"])"
    private static let focusFirst =
      "(function(){var e=document.querySelector('\(focusable)');if(e)e.focus();})()"
    private static let focusLast =
      "(function(){var e=document.querySelectorAll('\(focusable)');if(e.length)e[e.length-1].focus();})()"
  #elseif os(macOS)
    /// Stand just before and after the page in the window's key view loop. Tab past the page's last
    /// control (Shift+Tab past its first) makes WebKit pass focus to the window's next (previous) key
    /// view: one of these, which hands it back to Flutter.
    private lazy var before = Edge { [weak self] in self?.leave(.backward) }
    private lazy var after = Edge { [weak self] in self?.leave(.forward) }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      moved()
    }

    private func leave(_ direction: FocusDirection) {
      returnKeys()
      exit(direction)
    }

    /// Gives keyboard focus back to the Flutter view this platform view is in.
    private func returnKeys() {
      var view = superview
      while let candidate = view, !(candidate.nextResponder is FlutterViewController) { view = candidate.superview }
      if let flutterView = view { flutterView.window?.makeFirstResponder(flutterView) }
    }

    /// A stop in the window's key view loop that reports arriving there.
    private final class Edge: NSView {
      private let reached: () -> Void

      init(_ reached: @escaping () -> Void) {
        self.reached = reached
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) { fatalError("not used") }

      override var acceptsFirstResponder: Bool { true }

      override func becomeFirstResponder() -> Bool {
        // After AppKit finishes changing the first responder.
        DispatchQueue.main.async(execute: reached)
        return true
      }
    }
  #endif
}
