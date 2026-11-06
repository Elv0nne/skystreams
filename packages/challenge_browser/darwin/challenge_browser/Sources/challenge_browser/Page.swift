import WebKit

#if os(iOS)
  import UIKit
  typealias NativeView = UIView
#elseif os(macOS)
  import AppKit
  typealias NativeView = NSView
#endif

/// One page: a WKWebView of its own. It waits in the plugin's hidden host until a platform view
/// adopts it, and goes back there when the view goes, so a shown page is never reloaded.
@MainActor
final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
  let webView: PageWebView
  private let emit: (PageEvent) -> Void
  private var progress: NSKeyValueObservation?

  /// The platform view showing the page, if one is.
  weak var container: PageContainer?

  /// A focus request that came before the page was shown: forward, backward, or none.
  private var pendingFocus: Bool?

  /// Main-frame URLs starting with one of these are stopped and reported, not loaded.
  var navigationStops: [String] = []

  /// The folders the page serves (`serveFolder`, Phase 7c's §6).
  private let folders: FolderServer

  /// Whether the page's dialogs wait for Dart (`holdDialogs`); else they're answered at once, as WebKit answers them
  /// with no delegate.
  var holdsDialogs = false

  /// The held dialogs Dart hasn't answered, by id: each takes accept and a prompt's text.
  private var dialogs: [Int64: (Bool, String?) -> Void] = [:]
  private var nextDialog: Int64 = 0

  init(channel: String, emit: @escaping (PageEvent) -> Void) {
    self.emit = emit
    let configuration = WKWebViewConfiguration()
    // The default store: a clearance one page earns serves the next.
    configuration.websiteDataStore = .default()
    if #available(iOS 17.0, macOS 14.0, *) {
      // WebKit slows down pages nobody sees; a hidden page is still working.
      configuration.preferences.inactiveSchedulingPolicy = .none
    }
    #if os(iOS)
      configuration.allowsInlineMediaPlayback = true
    #elseif os(macOS)
      // Tab reaches every control, a challenge's checkbox included, not only text fields.
      configuration.preferences.tabFocusesLinks = true
    #endif
    // Its own folders' scheme, which WebKit takes only before the web view is made.
    let folders = FolderServer()
    configuration.setURLSchemeHandler(folders, forURLScheme: FolderServer.scheme)
    self.folders = folders
    webView = PageWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
    super.init()
    configuration.userContentController.add(WeakHandler(self), contentWorld: .page, name: channel)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    #if os(iOS)
      // Flutter lays out around the safe area itself.
      webView.scrollView.contentInsetAdjustmentBehavior = .never
    #elseif os(macOS)
      webView.focusChanged = { [weak self] focused in self?.emit(PageEvent(kind: focused ? .focused : .blurred)) }
    #endif
    progress = webView.observe(\.estimatedProgress) { [weak self] view, _ in
      // WebKit changes it on the main thread.
      MainActor.assumeIsolated { self?.emit(PageEvent(kind: .progress, progress: view.estimatedProgress)) }
    }
  }

  func load(_ url: String, headers: [String: String]) throws {
    guard let target = URL(string: url) else {
      throw PigeonError(code: "bad-url", message: "Not a URL: \(url)", details: nil)
    }
    var request = URLRequest(url: target)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    webView.load(request)
  }

  /// The script's result as JSON: "null" for undefined, and for values JSON can't hold.
  func evaluate(_ script: String) async throws -> String {
    Page.json(try await run(script))
  }

  /// [script] in a content world of SkyStream's: it sees the page's DOM, but the page's scripts can't
  /// see it, or anything it defines.
  func evaluateIsolated(_ script: String) async throws -> String {
    Page.json(try await run(script, in: .defaultClient))
  }

  #if os(macOS)
    /// A click at [x], [y] CSS pixels from the page's top left, as the window's own mouse events: a
    /// short move to the point, as a hand on a mouse makes, then a press and a release. Sent straight
    /// to the web view, so the page needn't be shown, and the app keeps its keyboard focus.
    func tap(x: Double, y: Double) async {
      guard let window = webView.window else { return }
      let inView = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
      let target = webView.convert(inView, to: nil)
      let start = NSPoint(x: target.x - 140, y: target.y + 70)
      func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseDown ? 1 : 0)
      }
      for step in 1...14 {
        let t = Double(step) / 14
        let eased = t * t * (3 - 2 * t)
        let point = NSPoint(x: start.x + (target.x - start.x) * eased, y: start.y + (target.y - start.y) * eased)
        if let move = mouse(.mouseMoved, point) { webView.mouseMoved(with: move) }
        try? await Task.sleep(nanoseconds: 16_000_000)
      }
      if let down = mouse(.leftMouseDown, target) { webView.mouseDown(with: down) }
      try? await Task.sleep(nanoseconds: UInt64(80_000_000 + Int.random(in: 0...60_000_000)))
      if let up = mouse(.leftMouseUp, target) { webView.mouseUp(with: up) }
    }
  #endif

  func addDocumentStartScript(_ script: String) {
    webView.configuration.userContentController.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
  }

  func cookies(_ url: String) async -> [PageCookie] {
    await matching(url).map { cookie in
      PageCookie(
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path,
        expiresMs: cookie.expiresDate.map { Int64($0.timeIntervalSince1970 * 1000) },
        httpOnly: cookie.isHTTPOnly,
        secure: cookie.isSecure)
    }
  }

  func deleteCookies(_ url: String, name: String?) async {
    let store = webView.configuration.websiteDataStore.httpCookieStore
    for cookie in await matching(url) where name == nil || cookie.name == name {
      await store.deleteCookie(cookie)
    }
  }

  func userAgent() async throws -> String {
    try await run("navigator.userAgent") as? String ?? ""
  }

  func setUserAgent(_ agent: String) {
    webView.customUserAgent = agent
  }

  /// The page's title as WebKit has it: nothing runs in the page, which may be waiting in a held dialog.
  var title: String? { webView.title }

  /// Serves [folder] under [name], read-only, and returns its address's base (`cbfolder://<name>/`).
  func serveFolder(_ name: String, folder: String) -> String {
    folders.serve(name, folder: folder)
  }

  /// Answers held dialog [id]: [accept] for a confirm, [text] (nil when not [accept]) for a prompt.
  func answerDialog(_ id: Int64, accept: Bool, text: String?) {
    dialogs.removeValue(forKey: id)?(accept, text)
  }

  func focus(forward: Bool) {
    guard let container else {
      pendingFocus = forward
      return
    }
    container.enter(forward: forward)
  }

  func blur() {
    pendingFocus = nil
    container?.blur()
  }

  /// The focus request that came before the page was shown, once.
  func takePendingFocus() -> Bool? {
    defer { pendingFocus = nil }
    return pendingFocus
  }

  func destroy() {
    // WebKit raises over a dialog's handler never called: each held one is cancelled.
    for answer in dialogs.values { answer(false, nil) }
    dialogs.removeAll()
    webView.uiDelegate = nil
    progress = nil
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeAllScriptMessageHandlers()
    webView.removeFromSuperview()
  }

  /// The script's result; nil for undefined and for values WebKit can't return (a promise, say).
  private func run(_ script: String, in world: WKContentWorld = .page) async throws -> Any? {
    try await withCheckedThrowingContinuation { done in
      webView.evaluateJavaScript(script, in: nil, in: world) { result in
        switch result {
        case .success(let value):
          done.resume(returning: value)
        case .failure(let error as WKError) where error.code == .javaScriptResultTypeIsUnsupported:
          done.resume(returning: nil)
        case .failure(let error):
          done.resume(throwing: PigeonError(code: "script", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// The cookies WebKit would send to [url].
  private func matching(_ url: String) async -> [HTTPCookie] {
    guard let target = URL(string: url), let host = target.host?.lowercased() else { return [] }
    let secure = target.scheme == "https"
    let path = target.path.isEmpty ? "/" : target.path
    return await webView.configuration.websiteDataStore.httpCookieStore.allCookies().filter { cookie in
      let domain = cookie.domain.lowercased()
      let domainMatches =
        domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
      let directory = cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"
      let pathMatches = path == cookie.path || path.hasPrefix(directory)
      return domainMatches && pathMatches && (secure || !cookie.isSecure)
    }
  }

  /// Whether [url] is one of [navigationStops]: if so, reports it, and the caller stops it.
  private func stopped(_ url: URL?) -> Bool {
    guard let url = url?.absoluteString, navigationStops.contains(where: { url.hasPrefix($0) }) else {
      return false
    }
    emit(PageEvent(kind: .navigationStopped, url: url))
    return true
  }

  // MARK: WKNavigationDelegate

  // Asked for the page's own navigations and for each redirect: a sign-in's redirect is caught here
  // before anything is requested from it.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
    decisionHandler(mainFrame && stopped(navigationAction.request.url) ? .cancel : .allow)
  }

  func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
    // A redirect the policy check didn't see.
    if stopped(webView.url) { webView.stopLoading() }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    emit(PageEvent(kind: .pageStarted, url: webView.url?.absoluteString))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    emit(PageEvent(kind: .pageFinished, url: webView.url?.absoluteString))
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failed(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    failed(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    // WebKit doesn't say why: a crash and the system reclaiming memory look the same.
    emit(PageEvent(kind: .rendererGone, crashed: true))
  }

  private func failed(_ error: Error) {
    let error = error as NSError
    emit(
      PageEvent(
        kind: .pageError,
        url: (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? webView.url?.absoluteString,
        code: Int64(error.code),
        errorText: error.localizedDescription,
        mainFrame: true))
  }

  // MARK: WKUIDelegate

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    guard holdsDialogs else { return completionHandler() }
    hold(.alert, message, nil, frame) { _, _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard holdsDialogs else { return completionHandler(false) }
    hold(.confirm, message, nil, frame) { accept, _ in completionHandler(accept) }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void
  ) {
    guard holdsDialogs else { return completionHandler(nil) }
    hold(.prompt, prompt, defaultText, frame) { accept, text in completionHandler(accept ? (text ?? "") : nil) }
  }

  /// Keeps [answer] until Dart answers the dialog, and reports it. The page waits meanwhile; the app runs on.
  private func hold(
    _ kind: DialogKind, _ message: String, _ defaultText: String?, _ frame: WKFrameInfo,
    _ answer: @escaping (Bool, String?) -> Void
  ) {
    nextDialog += 1
    dialogs[nextDialog] = answer
    emit(
      PageEvent(
        kind: .dialog, url: frame.request.url?.absoluteString ?? webView.url?.absoluteString, message: message,
        dialogId: nextDialog, dialogKind: kind, defaultText: defaultText))
  }

  // MARK: WKScriptMessageHandler

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    emit(PageEvent(kind: .scriptMessage, message: message.body as? String ?? Page.json(message.body)))
  }

  private static func json(_ value: Any?) -> String {
    // Checked first: JSONSerialization raises an exception, not an error, for dates and NaN.
    guard let value, JSONSerialization.isValidJSONObject([value]),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}

/// The page's WKWebView.
final class PageWebView: WKWebView {
  #if os(macOS)
    /// Called when the page takes keyboard focus, and when it loses it. Flutter hears of neither from
    /// a click: the macOS engine doesn't report focus going to a platform view.
    var focusChanged: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { focusChanged(true) }
      return became
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { focusChanged(false) }
      return resigned
    }
  #endif
}

/// WKUserContentController keeps its message handlers; this one doesn't keep the page.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
  private weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) { self.target = target }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(controller, didReceive: message)
  }
}
