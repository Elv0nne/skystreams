#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import FlutterMacOS
  import AppKit
#endif

/// Runs each `ChallengeBrowser` page in a WKWebView of its own, and shows it in a platform view.
@MainActor
public final class ChallengeBrowserPlugin: NSObject, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
  private let events: PageFlutterApi
  private var pages: [Int64: Page] = [:]
  private var nextId: Int64 = 0

  /// Holds hidden pages inside Flutter's view, where WebKit runs them at full speed.
  private var host: HiddenHost?

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    events = PageFlutterApi(binaryMessenger: registrar.binaryMessenger)
  }

  // Flutter registers plugins on the main thread.
  nonisolated public static func register(with registrar: FlutterPluginRegistrar) {
    MainActor.assumeIsolated {
      let plugin = ChallengeBrowserPlugin(registrar: registrar)
      PageHostApiSetup.setUp(binaryMessenger: registrar.binaryMessenger, api: plugin)
      let factory = PageViewFactory { [weak plugin] pageId in
        PageContainer(page: plugin?.pages[pageId], host: plugin?.hiddenHost()) { direction in
          plugin?.emit(pageId, PageEvent(kind: .focusExit, direction: direction))
        }
      }
      registrar.register(factory, withId: "dev.akash.challenge_browser/page")
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    PageHostApiSetup.setUp(binaryMessenger: registrar.binaryMessenger, api: nil)
    for page in pages.values { page.destroy() }
    pages.removeAll()
    host?.removeFromSuperview()
  }

  private func emit(_ pageId: Int64, _ event: PageEvent) {
    Task { try? await events.onEvent(pageId: pageId, event: event) }
  }

  private func page(_ id: Int64) throws -> Page {
    guard let page = pages[id] else { throw PigeonError(code: "no-page", message: "No page \(id)", details: nil) }
    return page
  }

  /// The hidden host, behind everything else in Flutter's view. Nil until that view is in a window.
  private func hiddenHost() -> HiddenHost? {
    if let host, host.window != nil { return host }
    #if os(iOS)
      guard let flutterView = registrar.viewController?.view, flutterView.window != nil else { return nil }
      let host = HiddenHost(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
      flutterView.insertSubview(host, at: 0)
    #elseif os(macOS)
      guard let flutterView = registrar.view, flutterView.window != nil else { return nil }
      let host = HiddenHost(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
      flutterView.addSubview(host, positioned: .below, relativeTo: nil)
    #endif
    self.host = host
    return host
  }
}

extension ChallengeBrowserPlugin: @preconcurrency PageHostApi {
  func create(scriptChannel: String) async throws -> Int64 {
    nextId += 1
    let id = nextId
    let page = Page(channel: scriptChannel) { [weak self] event in self?.emit(id, event) }
    pages[id] = page
    hiddenHost()?.addSubview(page.webView)
    return id
  }

  func load(pageId: Int64, url: String, headers: [String: String]) throws {
    try page(pageId).load(url, headers: headers)
  }

  func evaluate(pageId: Int64, script: String) async throws -> String {
    try await page(pageId).evaluate(script)
  }

  func addDocumentStartScript(pageId: Int64, script: String) throws {
    try page(pageId).addDocumentStartScript(script)
  }

  func cookies(pageId: Int64, url: String) async throws -> [PageCookie] {
    try await page(pageId).cookies(url)
  }

  func deleteCookies(pageId: Int64, url: String, name: String?) async throws {
    try await page(pageId).deleteCookies(url, name: name)
  }

  func userAgent(pageId: Int64) async throws -> String {
    try await page(pageId).userAgent()
  }

  func setUserAgent(pageId: Int64, userAgent: String) throws {
    try page(pageId).setUserAgent(userAgent)
  }

  /// WebKit reports no requests to the app: Dart watches them from inside the page.
  func setCapture(pageId: Int64, enabled: Bool) throws {}

  /// Platform views show pages here.
  func setFrame(pageId: Int64, frame: PageFrame?) throws {}

  func focus(pageId: Int64, forward: Bool) throws {
    try page(pageId).focus(forward: forward)
  }

  func blur(pageId: Int64) throws {
    try page(pageId).blur()
  }

  func setNavigationStops(pageId: Int64, prefixes: [String]) throws {
    try page(pageId).navigationStops = prefixes
  }

  func tap(pageId: Int64, x: Double, y: Double) async throws {
    #if os(macOS)
      try await page(pageId).tap(x: x, y: y)
    #else
      throw PigeonError(code: "unsupported", message: "iOS has no allowed way to send a touch", details: nil)
    #endif
  }

  func evaluateIsolated(pageId: Int64, script: String) async throws -> String {
    try await page(pageId).evaluateIsolated(script)
  }

  func capabilities() throws -> PageCapabilities {
    #if os(macOS)
      PageCapabilities(canTap: true, isolatedWorlds: true)
    #else
      // iOS has no allowed way to send a touch into a web view: the person ticks there.
      PageCapabilities(canTap: false, isolatedWorlds: true)
    #endif
  }

  func engineVersion() throws -> String { "" }

  func devTools(pageId: Int64, method: String, paramsJson: String) async throws -> String {
    throw PigeonError(code: "unsupported", message: "DevTools calls are for Windows only", details: nil)
  }

  func serveFolder(pageId: Int64, name: String, folder: String) throws -> String {
    try page(pageId).serveFolder(name, folder: folder)
  }

  func holdDialogs(pageId: Int64, hold: Bool) throws {
    try page(pageId).holdsDialogs = hold
  }

  func answerDialog(pageId: Int64, dialogId: Int64, accept: Bool, text: String?) throws {
    try page(pageId).answerDialog(dialogId, accept: accept, text: text)
  }

  func title(pageId: Int64) throws -> String? {
    try page(pageId).title
  }

  func dispose(pageId: Int64) async throws {
    pages.removeValue(forKey: pageId)?.destroy()
  }
}

/// Invisible, and out of the way of touches, clicks and accessibility.
private final class HiddenHost: NativeView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    #if os(iOS)
      alpha = 0
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
    #elseif os(macOS)
      alphaValue = 0
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? { [] }
  #endif
}

extension FlutterPluginRegistrar {
  fileprivate var binaryMessenger: FlutterBinaryMessenger {
    #if os(iOS)
      messenger()
    #elseif os(macOS)
      messenger
    #endif
  }
}
