import Cocoa
import FlutterMacOS
import VLCKit

public class VlcPlayerPlugin: NSObject, FlutterPlugin {
  private let messenger: FlutterBinaryMessenger
  private let textures: FlutterTextureRegistry
  private let methodChannel: FlutterMethodChannel
  private var players: [Int64: VlcPlayerPlatformView] = [:]

  /// Texture players get their ids from here, counting down from -1.
  ///
  /// Platform-view players are keyed by the id Flutter assigned their view,
  /// which is always non-negative, so the two id spaces cannot collide even
  /// though a host is free to mix both renderers.
  private var nextTextureViewId: Int64 = -1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VlcPlayerPlugin(
      binaryMessenger: registrar.messenger,
      textures: registrar.textures
    )
    let factory = VlcPlayerViewFactory(messenger: registrar.messenger) { [weak instance] viewId, player in
      instance?.players.removeValue(forKey: viewId)?.dispose()
      instance?.players[viewId] = player
    }

    registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
    registrar.register(factory, withId: "plugins.lingjhf.com/vlc_player/view")
  }

  init(binaryMessenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
    messenger = binaryMessenger
    self.textures = textures
    methodChannel = FlutterMethodChannel(name: "vlc_player", binaryMessenger: binaryMessenger)
    super.init()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Deliberately ahead of the viewId guard: `create` is the call that mints
    // one, so it is the only method that arrives without it.
    if call.method == "create" {
      createTexturePlayer(arguments: call.arguments as? [String: Any] ?? [:], result: result)
      return
    }

    guard let arguments = call.arguments as? [String: Any],
          let viewId = Self.int64Value(arguments["viewId"]) else {
      result(FlutterError(code: "invalid_args", message: "A valid viewId is required.", details: nil))
      return
    }

    if call.method == "dispose" {
      disposePlayer(viewId: viewId, result: result)
      return
    }

    guard let player = players[viewId] else {
      result(FlutterError(code: "player_not_found", message: "No vlc_player player exists for viewId \(viewId).", details: nil))
      return
    }

    DispatchQueue.main.async {
      self.handle(call.method, arguments: arguments, player: player, result: result)
    }
  }

  private func handle(
    _ method: String,
    arguments: [String: Any],
    player: VlcPlayerPlatformView,
    result: @escaping FlutterResult
  ) {
    guard !player.isDisposed else {
      result(Self.disposedError())
      return
    }

    switch method {
    case "setSource":
      guard let uri = arguments["uri"] as? String, !uri.isEmpty else {
        result(FlutterError(code: "invalid_args", message: "A non-empty uri is required.", details: nil))
        return
      }
      let autoPlay = arguments["autoPlay"] as? Bool ?? false
      let httpHeaders = arguments["httpHeaders"] as? [String: String] ?? [:]
      let mediaOptions = arguments["mediaOptions"] as? [String] ?? []
      let startPosition = Self.intValue(arguments["startPosition"]) ?? 0
      guard startPosition >= 0 else {
        result(FlutterError(code: "invalid_args", message: "A non-negative startPosition is required.", details: nil))
        return
      }
      player.setSource(
        uri,
        httpHeaders: httpHeaders,
        mediaOptions: mediaOptions,
        startPosition: startPosition,
        keepPicture: arguments["keepPicture"] as? Bool ?? false,
        autoPlay: autoPlay,
        result: result
      )
    case "play":
      player.play()
      result(nil)
    case "pause":
      player.pause()
      result(nil)
    case "stop":
      player.stop()
      result(nil)
    case "seekTo":
      guard let position = Self.intValue(arguments["position"]), position >= 0 else {
        result(FlutterError(code: "invalid_args", message: "A non-negative position is required.", details: nil))
        return
      }
      player.seekTo(milliseconds: position)
      result(nil)
    case "seekToFraction":
      guard let fraction = Self.doubleValue(arguments["fraction"]), fraction.isFinite, fraction >= 0, fraction <= 1 else {
        result(FlutterError(code: "invalid_args", message: "A fraction within 0..1 is required.", details: nil))
        return
      }
      player.seekToFraction(fraction)
      result(nil)
    case "setVolume":
      guard let volume = Self.intValue(arguments["volume"]) else {
        result(FlutterError(code: "invalid_args", message: "A volume value is required.", details: nil))
        return
      }
      player.setVolume(volume)
      result(nil)
    case "setPlaybackSpeed":
      guard let speed = Self.doubleValue(arguments["speed"]), speed.isFinite && speed > 0 else {
        result(FlutterError(code: "invalid_args", message: "A finite positive playback speed is required.", details: nil))
        return
      }
      player.setPlaybackSpeed(speed)
      result(nil)
    case "setAudioDelay":
      guard let delay = Self.intValue(arguments["delay"]) else {
        result(FlutterError(code: "invalid_args", message: "An audio delay value is required.", details: nil))
        return
      }
      player.setAudioDelay(delay)
      result(nil)
    case "setSubtitleLook":
      guard let textScale = Self.intValue(arguments["textScale"]),
            let color = Self.intValue(arguments["color"]),
            let backgroundColor = Self.intValue(arguments["backgroundColor"]),
            let backgroundOpacity = Self.intValue(arguments["backgroundOpacity"]),
            let outlineThickness = Self.intValue(arguments["outlineThickness"]),
            let raise = (arguments["raise"] as? NSNumber)?.doubleValue else {
        result(FlutterError(code: "invalid_args", message: "Every subtitle look value is required.", details: nil))
        return
      }
      result(player.setSubtitleLook(
        textScale: textScale,
        color: color,
        backgroundColor: backgroundColor,
        backgroundOpacity: backgroundOpacity,
        outlineThickness: outlineThickness,
        raise: raise))
    case "setSubtitleDelay":
      guard let delay = Self.intValue(arguments["delay"]) else {
        result(FlutterError(code: "invalid_args", message: "A subtitle delay value is required.", details: nil))
        return
      }
      player.setSubtitleDelay(delay)
      result(nil)
    case "takeSnapshot":
      let rawWidth = Self.intValue(arguments["width"])
      let rawHeight = Self.intValue(arguments["height"])
      if let rawWidth = rawWidth, rawWidth <= 0 {
        result(FlutterError(code: "invalid_args", message: "Snapshot dimensions must be positive.", details: nil))
        return
      }
      if let rawHeight = rawHeight, rawHeight <= 0 {
        result(FlutterError(code: "invalid_args", message: "Snapshot dimensions must be positive.", details: nil))
        return
      }
      let width = rawWidth ?? 0
      let height = rawHeight ?? 0
      player.takeSnapshot(width: width, height: height, result: result)
    case "getAudioTracks":
      result(player.getAudioTracks())
    case "setAudioTrack":
      guard let id = Self.intValue(arguments["id"]), id >= 0 else {
        result(FlutterError(code: "invalid_args", message: "A non-negative audio track id is required.", details: nil))
        return
      }
      guard player.setAudioTrack(id) else {
        result(FlutterError(code: "track_not_found", message: "Audio track \(id) was not found.", details: nil))
        return
      }
      result(nil)
    case "getSubtitleTracks":
      result(player.getSubtitleTracks())
    case "setSubtitleTrack":
      guard let id = Self.intValue(arguments["id"]), id >= 0 else {
        result(FlutterError(code: "invalid_args", message: "A non-negative subtitle track id is required.", details: nil))
        return
      }
      guard player.setSubtitleTrack(id) else {
        result(FlutterError(code: "track_not_found", message: "Subtitle track \(id) was not found.", details: nil))
        return
      }
      result(nil)
    case "disableSubtitle":
      player.disableSubtitle()
      result(nil)
    case "addSubtitle":
      guard let uri = arguments["uri"] as? String, !uri.isEmpty else {
        result(FlutterError(code: "invalid_args", message: "A non-empty subtitle uri is required.", details: nil))
        return
      }
      player.addSubtitle(uri, result: result)
    case "setFit":
      guard let fit = arguments["fit"] as? String else {
        result(FlutterError(code: "invalid_args", message: "A fit value is required.", details: nil))
        return
      }
      player.setFit(fit)
      result(nil)
    case "getMediaInfo":
      result(player.getMediaInfo())
    case "getMediaStats":
      result(player.getMediaStats())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Builds a texture-backed player and hands Dart both ids it needs.
  ///
  /// Mirrors the Windows plugin's `create`: the widget has no platform view to
  /// wait on, so the reply carries the viewId every later call is keyed by and
  /// the textureId the `Texture` widget renders.
  private func createTexturePlayer(arguments: [String: Any], result: @escaping FlutterResult) {
    let create = {
      let options = arguments["options"] as? [String] ?? []
      let viewId = self.nextTextureViewId
      self.nextTextureViewId -= 1

      let player = VlcPlayerPlatformView(
        viewId: viewId,
        messenger: self.messenger,
        options: options,
        target: .texture
      )
      guard let renderer = player.textureRenderer else {
        player.dispose()
        result(FlutterError(code: "create_failed", message: "Unable to attach a vlc_player texture.", details: nil))
        return
      }

      let textureId = self.textures.register(renderer)
      renderer.onFrameAvailable = { [weak self] in
        self?.textures.textureFrameAvailable(textureId)
      }
      player.textureId = textureId
      self.players[viewId] = player
      result(["viewId": viewId, "textureId": textureId])
    }
    if Thread.isMainThread {
      create()
    } else {
      DispatchQueue.main.async(execute: create)
    }
  }

  private func disposePlayer(viewId: Int64, result: FlutterResult? = nil) {
    let dispose = {
      let player = self.players.removeValue(forKey: viewId)
      // Before dispose(), so the engine stops asking a detached renderer for
      // frames rather than after it has already been silenced.
      if let textureId = player?.textureId {
        self.textures.unregisterTexture(textureId)
      }
      player?.dispose()
      result?(nil)
    }
    if Thread.isMainThread {
      dispose()
    } else {
      DispatchQueue.main.async(execute: dispose)
    }
  }

  private static func disposedError() -> FlutterError {
    return FlutterError(code: "disposed", message: "The vlc_player has been disposed.", details: nil)
  }

  private static func int64Value(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber {
      return number.int64Value
    }
    return value as? Int64
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
      return number.intValue
    }
    return value as? Int
  }

  private static func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    return value as? Double
  }
}

final class VlcPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  private let onCreate: (Int64, VlcPlayerPlatformView) -> Void

  init(
    messenger: FlutterBinaryMessenger,
    onCreate: @escaping (Int64, VlcPlayerPlatformView) -> Void
  ) {
    self.messenger = messenger
    self.onCreate = onCreate
    super.init()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let options = (args as? [String: Any])?["options"] as? [String] ?? []
    let fit = (args as? [String: Any])?["fit"] as? String ?? "contain"
    // The factory owns the view it has to hand back, so the player never has
    // to expose an optional one for the texture case to leave nil.
    let container = VlcPlayerContainerView()
    let platformView = VlcPlayerPlatformView(
      viewId: viewId,
      messenger: messenger,
      options: options,
      target: .appKitView(container, fit: fit)
    )
    onCreate(viewId, platformView)
    return container
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Where a player puts its pixels.
///
/// macOS supports both. The Flutter texture is the default since 2026-09-06:
/// an AppKitView makes the embedder composite every Flutter layer above it as
/// a separate surface, and any repaint of one dropped the video for a frame.
/// The view stays selectable through `VlcPlayerConfig.darwinRenderer`.
enum VlcRenderTarget {
  case appKitView(VlcPlayerContainerView, fit: String)
  case texture
}

final class VlcPlayerPlatformView: NSObject, VLCMediaPlayerDelegate {
  /// The registered Flutter texture id, set by the plugin after it registers
  /// `textureRenderer`. Nil for view-backed players.
  var textureId: Int64?

  private let renderTarget: VlcRenderTarget
  private(set) var textureRenderer: VlcTextureRenderer?
  /// libVLC's own events, the held picture and the refused-seek log, which
  /// VLCKit's delegate doesn't carry; moves with the player (replacePlayer).
  private var events: VlcPlayerEvents?
  /// Nil once disposed: dispose() hands the last reference to retire.
  /// Every caller runs before that - the plugin drops a disposed player from
  /// its map, and the delegate and event callbacks check isDisposed first.
  private var mediaPlayer: VLCMediaPlayer!
  private let eventChannel: FlutterEventChannel
  private let eventHandler = VlcPlayerEventStreamHandler()
  private var lastSentEvent: NSDictionary?
  /// Bumped whenever the audio + subtitle track SET changes. VLCKit has no
  /// per-ES delegate callback (only the `.esAdded` state, which does not say
  /// which kind of stream moved), so every snapshot diffs a fingerprint of
  /// the two lists instead.
  ///
  /// The fingerprint replaced a plain count, which could not see a same-size
  /// swap: an adaptive rendition change or an MPEG-TS PMT update replaces the
  /// tracks without changing how many there are, and a consumer that caches
  /// getAudioTracks() / getSubtitleTracks() off this counter was left drawing
  /// the previous names with nothing ticked, because the active id it matches
  /// no longer exists.
  private var trackRevision = 0
  private var lastTrackFingerprint: UInt64?
  private(set) var isDisposed = false
  /// Whether this player has been given a source: the next one gets a fresh
  /// player (replacePlayer).
  private var hasHadSource = false
  /// The volume last set, for a fresh player; nil until one is set.
  private var volume: Int32?
  /// The volume last set on any player, which every new one starts at. libVLC
  /// did that on macOS by saving the volume in its configuration (auhal's
  /// volume-save), which every new audio output read; FORK.md 32 turned that
  /// off. Main thread only.
  private static var lastVolume: Int32?
  /// The subtitle look last set, applied again to a fresh player.
  private var subtitleLook: (
    textScale: Int, color: Int, backgroundColor: Int, backgroundOpacity: Int,
    outlineThickness: Int, raise: Double
  )?

  init(
    viewId: Int64,
    messenger: FlutterBinaryMessenger,
    options: [String],
    target: VlcRenderTarget
  ) {
    renderTarget = target
    mediaPlayer = VLCMediaPlayer(library: Self.library(for: options))
    // libVLC's own log, which VLCKit drops unless a logger is set: the host's verbose switch (`--verbose=2`) reaches
    // the console only through one.
    if options.contains("--verbose=2") {
      let logger = VLCConsoleLogger()
      logger.level = .debug
      logger.formatter.contextFlags = .levelContextModule
      mediaPlayer.libraryInstance.loggers = [logger]
    }
    eventChannel = FlutterEventChannel(name: "vlc_player/events/\(viewId)", binaryMessenger: messenger)

    switch target {
    case let .appKitView(container, fit):
      Self.applyFit(fit, to: container)
      mediaPlayer.drawable = container
    case .texture:
      // Installed before any media is set: libVLC settles its video output
      // when playback starts, and callbacks added after that are ignored.
      textureRenderer = VlcTextureRenderer(mediaPlayer: mediaPlayer)
    }
    // libVLC's own buffering, track and time events, the held picture, and
    // its refused-seek log line, which VLCKit's delegate doesn't carry. The
    // log is read per library (library(for:)), and not under VLCKit's own
    // loggers, which take libVLC's one callback per instance.
    events = VlcPlayerEvents(
      mediaPlayer: mediaPlayer,
      renderer: textureRenderer,
      readLog: !options.contains("--verbose=2"))

    super.init()

    events?.onChanged = { [weak self] in
      self?.sendSnapshot()
    }

    mediaPlayer.delegate = self
    eventHandler.onListen = { [weak self] in
      self?.sendSnapshot(force: true)
    }
    eventChannel.setStreamHandler(eventHandler)
    if let volume = Self.lastVolume {
      self.volume = volume
      mediaPlayer.audio?.volume = volume
    }
    sendSnapshot()
  }

  func setSource(
    _ uri: String,
    httpHeaders: [String: String],
    mediaOptions: [String],
    startPosition: Int,
    keepPicture: Bool,
    autoPlay: Bool,
    result: @escaping FlutterResult
  ) {
    guard let url = URL(string: uri) else {
      result(FlutterError(code: "invalid_uri", message: "The provided uri is invalid.", details: uri))
      return
    }

    let media = VLCMedia(url: url)
    // HTTP headers are translated to libVLC options in Dart
    // (vlc_http_headers.dart). libVLC 3.x can transmit only User-Agent and
    // Referer; there is no `http-header` option, and emitting one here
    // silently dropped every header.
    for option in mediaOptions {
      media.addOption(option)
    }
    if startPosition > 0 {
      media.addOption(":start-time=\(Double(startPosition) / 1000.0)")
    }
    if hasHadSource {
      replacePlayer()
    }
    hasHadSource = true
    events?.arm(withKeepPicture: keepPicture)
    mediaPlayer.media = media
    sendSnapshot(force: true, stateOverride: "opening")
    if autoPlay {
      mediaPlayer.play()
    }
    result(nil)
  }

  func play() {
    mediaPlayer.play()
    sendSnapshot()
  }

  func pause() {
    mediaPlayer.pause()
    sendSnapshot()
  }

  func stop() {
    events?.stop()
    mediaPlayer.stop()
    sendSnapshot(stateOverride: "stopped")
  }

  func seekTo(milliseconds: Int) {
    mediaPlayer.time = VLCTime(number: NSNumber(value: milliseconds))
    sendSnapshot()
  }

  /// A place in a live HLS or DASH window, as libVLC's position fraction.
  func seekToFraction(_ fraction: Double) {
    mediaPlayer.position = Float(fraction)
    sendSnapshot()
  }

  func setVolume(_ volume: Int) {
    let clamped = Int32(max(0, min(200, volume)))
    self.volume = clamped
    Self.lastVolume = clamped
    mediaPlayer.audio?.volume = clamped
    sendSnapshot()
  }

  func setPlaybackSpeed(_ speed: Double) {
    mediaPlayer.rate = Float(speed)
    sendSnapshot()
  }

  func setAudioDelay(_ microseconds: Int) {
    mediaPlayer.currentAudioPlaybackDelay = microseconds
    sendSnapshot()
  }

  /// Restyles the subtitle lines libVLC draws, from their next line; whether
  /// this libVLC could. The variables stay on the player, for every media it
  /// is given after.
  ///
  /// [raise] is a share of the picture's height, and libVLC takes pixels of
  /// what it lays the lines out on: for the texture, the picture itself,
  /// blended into a buffer of its size. Dart sends the look again whenever the
  /// picture changes size. A drawable lays them out on the picture on screen,
  /// where the raise comes out smaller than asked when that is the larger.
  func setSubtitleLook(
    textScale: Int,
    color: Int,
    backgroundColor: Int,
    backgroundOpacity: Int,
    outlineThickness: Int,
    raise: Double
  ) -> Bool {
    subtitleLook = (
      textScale, color, backgroundColor, backgroundOpacity, outlineThickness,
      raise
    )
    let height = Double(mediaPlayer.videoSize.height)
    let margin = raise > 0 && height > 0 ? Int((min(raise, 0.5) * height).rounded()) : 0
    return VlcTextureRenderer.applySubtitleLook(
      to: mediaPlayer,
      textScale: textScale,
      color: color,
      backgroundColor: backgroundColor,
      backgroundOpacity: backgroundOpacity,
      outlineThickness: outlineThickness,
      margin: margin)
  }

  func setSubtitleDelay(_ microseconds: Int) {
    mediaPlayer.currentVideoSubTitleDelay = microseconds
    sendSnapshot()
  }

  func takeSnapshot(width: Int, height: Int, result: @escaping FlutterResult) {
    guard mediaPlayer.media != nil else {
      result(FlutterError(code: "snapshot_failed", message: "No media is loaded.", details: nil))
      return
    }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "vlc_player_snapshot_\(UUID().uuidString).png"
    )
    try? FileManager.default.removeItem(at: url)
    mediaPlayer.saveVideoSnapshot(at: url.path, withWidth: Int32(width), andHeight: Int32(height))

    DispatchQueue.global(qos: .userInitiated).async {
      for _ in 0..<40 {
        if let data = try? Data(contentsOf: url), !data.isEmpty {
          try? FileManager.default.removeItem(at: url)
          DispatchQueue.main.async {
            result(FlutterStandardTypedData(bytes: data))
          }
          return
        }
        Thread.sleep(forTimeInterval: 0.05)
      }

      try? FileManager.default.removeItem(at: url)
      DispatchQueue.main.async {
        result(FlutterError(code: "snapshot_failed", message: "VLC did not produce snapshot image data.", details: nil))
      }
    }
  }

  func getAudioTracks() -> [[String: Any?]] {
    return trackDescriptions(indexes: mediaPlayer.audioTrackIndexes, names: mediaPlayer.audioTrackNames)
  }

  func setAudioTrack(_ id: Int) -> Bool {
    guard trackIndexes(mediaPlayer.audioTrackIndexes).contains(id) else {
      return false
    }
    mediaPlayer.currentAudioTrackIndex = Int32(id)
    // No ES delegate callback tells us the switch landed; publish it now.
    sendSnapshot(force: true)
    return true
  }

  func getSubtitleTracks() -> [[String: Any?]] {
    return trackDescriptions(indexes: mediaPlayer.videoSubTitlesIndexes, names: mediaPlayer.videoSubTitlesNames)
  }

  func setSubtitleTrack(_ id: Int) -> Bool {
    guard trackIndexes(mediaPlayer.videoSubTitlesIndexes).contains(id) else {
      return false
    }
    mediaPlayer.currentVideoSubTitleIndex = Int32(id)
    sendSnapshot(force: true)
    return true
  }

  func disableSubtitle() {
    mediaPlayer.currentVideoSubTitleIndex = -1
    sendSnapshot(force: true)
  }

  func addSubtitle(_ uri: String, result: @escaping FlutterResult) {
    guard let url = URL(string: uri) else {
      result(FlutterError(code: "invalid_uri", message: "The provided subtitle uri is invalid.", details: uri))
      return
    }
    let status = mediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: true)
    if status != 0 {
      result(FlutterError(code: "add_subtitle_failed", message: "Failed to add subtitle: \(uri)", details: status))
      return
    }
    // Unlike the three selection mutations above, this one cannot report its
    // own result: libVLC 3 posts an added slave to the input thread, so a
    // zero status only means the slave was accepted and this snapshot still
    // carries the pre-add track lists. It is forced to keep the rest of the
    // payload fresh, not to announce the subtitle. VLCKit surfaces the new
    // elementary stream as a `.esAdded` state change, and the snapshot sent
    // from there is the one whose trackFingerprint moves trackRevision -
    // which is what a caller has to wait on, not this result.
    sendSnapshot(force: true)
    result(nil)
  }

  func getMediaInfo() -> [String: Any?] {
    let media = mediaPlayer.media
    return [
      "title": media?.metaData.title,
      "artist": media?.metaData.artist,
      "album": media?.metaData.album,
      "duration": Self.milliseconds(from: media?.length),
      "videoTracks": mediaTracks(media, matching: "video"),
      "audioTracks": mediaTracks(media, matching: "audio"),
      "subtitleTracks": mediaTracks(media, matching: "subtitle"),
    ]
  }

  func getMediaStats() -> [String: Any] {
    guard let media = mediaPlayer.media else {
      return Self.emptyMediaStats()
    }

    let stats = media.statistics
    return [
      "available": true,
      "readBytes": Int(stats.readBytes),
      "inputBitrate": Double(stats.inputBitrate),
      "demuxReadBytes": Int(stats.demuxReadBytes),
      "demuxBitrate": Double(stats.demuxBitrate),
      "demuxCorrupted": Int(stats.demuxCorrupted),
      "demuxDiscontinuity": Int(stats.demuxDiscontinuity),
      "decodedVideo": Int(stats.decodedVideo),
      "decodedAudio": Int(stats.decodedAudio),
      "displayedPictures": Int(stats.displayedPictures),
      "lostPictures": Int(stats.lostPictures),
      "playedAudioBuffers": Int(stats.playedAudioBuffers),
      "lostAudioBuffers": Int(stats.lostAudioBuffers),
      "sentPackets": Int(stats.sentPackets),
      "sentBytes": Int(stats.sentBytes),
      "sendBitrate": Double(stats.sendBitrate),
    ]
  }

  /// libVLC instances by the options they were made with, kept for the
  /// process's life, so that no released player ever ends one.
  ///
  /// VLCKit gives a player made with options an instance of its own, and
  /// ending an instance saves libVLC's configuration while holding the
  /// configuration lock for reading, taken twice (3.0.24 file.c,
  /// config_AutoSaveConfigFile). Darwin's lock makes a reader wait behind a
  /// queued writer, and libVLC writes its configuration from its own threads
  /// (the audio output at every start and close: auhal.c's VolumeSet and
  /// Close), so an instance ending beside such a write deadlocked both, and
  /// then every thread that read the configuration, main included (FORK.md
  /// 23). One instance per set of options, which is a handful, and none ends
  /// while the app runs.
  private static var libraries: [[String]: VLCLibrary] = [:]

  /// Main thread only, where every player is made.
  private static func library(for options: [String]) -> VLCLibrary {
    if let library = libraries[options] {
      return library
    }
    // Two of VLCKit's defaults off, after the host's options so they win over
    // VLCKit's own, which it puts in front (VLCLibrary.m, _defaultOptions):
    // macOS's --play-and-pause, which pauses at every end - a finished film and
    // a lost connection's false end alike - and volume-save, auhal's write of
    // the volume into libVLC's configuration at every sound start and volume
    // change, which can deadlock with the save VLCKit makes after every input
    // close (FORK.md 32). Nothing reads that configuration back: VLCKit leaves
    // ignore-config on.
    let library = VLCLibrary(options: options + ["--no-play-and-pause", "--no-volume-save"])
    if !options.contains("--verbose=2") {
      VlcPlayerEvents.readLog(of: library)
    }
    libraries[options] = library
    return library
  }

  /// Where released players go: concurrent, so one stuck behind a stalled
  /// download doesn't hold up the next.
  private static let releaseQueue = DispatchQueue(
    label: "vlc_player.release", qos: .utility, attributes: .concurrent)

  /// Holds the only reference the plugin has left, so the release happens
  /// exactly where it is let go.
  private final class Retired {
    var player: VLCMediaPlayer?
    init(_ player: VLCMediaPlayer) { self.player = player }
  }

  /// Where retired players stop, one at a time.
  ///
  /// A retired player's own thread closes its input, saves libVLC's
  /// configuration under a read lock it takes twice (VLCKit's patches 0014 and
  /// 0023), then closes its audio output, which writes that configuration
  /// (auhal's Close, always). Two retired players doing that at once
  /// deadlocked, and then every thread that reads the configuration, main
  /// included (FORK.md 32). One at a time, the save and the write never meet.
  private static let retireQueue = DispatchQueue(
    label: "vlc_player.retire", qos: .utility)

  /// Signals when the player it is attached to has gone.
  private final class Gone {
    let signal: DispatchSemaphore
    init(_ signal: DispatchSemaphore) { self.signal = signal }
    deinit { signal.signal() }
  }

  private static var goneKey: UInt8 = 0

  /// Pauses [player] now, then stops it and lets it go (releaseLater) once
  /// every player retired before it has gone, or has had 2 s to: a stalled
  /// stream can hold its close for minutes, and the next one then goes anyway.
  static func retire(_ player: VLCMediaPlayer) {
    player.pause()
    let retired = Retired(player)
    retireQueue.async {
      let gone = DispatchSemaphore(value: 0)
      if let player = retired.player {
        objc_setAssociatedObject(
          player, &goneKey, Gone(gone), .OBJC_ASSOCIATION_RETAIN)
        // libvlc_media_player_stop_async: the player's own thread closes the
        // input, saves the configuration and closes the audio output, and
        // -dealloc joins that thread.
        player.stop()
        releaseLater(player)
      }
      retired.player = nil
      _ = gone.wait(timeout: .now() + 2)
    }
  }

  /// Lets [player] go off the main thread, then runs [then] on main.
  ///
  /// VLCKit 3.7.4's -[VLCMediaPlayer dealloc] releases the libVLC player,
  /// which waits for the stream an asynchronous stop began stopping (VLCKit's
  /// patch 0023): 130 s on a stalled HLS download on iOS (spec 3). VLCKit
  /// also holds the player for a main-queue turn after a stop - its Stopped
  /// handler runs on main - so the reference is kept past two turns, as on
  /// iOS, then let go on a queue of its own.
  static func releaseLater(_ player: VLCMediaPlayer, then: (() -> Void)? = nil) {
    let retired = Retired(player)
    DispatchQueue.main.async {
      DispatchQueue.main.async {
        releaseQueue.async {
          retired.player = nil
          if let then {
            DispatchQueue.main.async(execute: then)
          }
        }
      }
    }
  }

  /// Puts a fresh player in place for the next source and hands the old one
  /// to retire.
  ///
  /// VLCKit 3.7.4 starts a media set with set_media_async only once the old
  /// input has closed (patch 0023: play() sets open_next while close_input is
  /// pending, and the worker thread opens the new input after input_Close),
  /// and a stalled HLS segment kept that close waiting for as long as the
  /// stall: a reconnect from a stalled stream could not start. Android,
  /// Windows and Linux make a fresh player per source too (FORK.md 10 and 21).
  private func replacePlayer() {
    let old: VLCMediaPlayer = mediaPlayer
    let next = VLCMediaPlayer(library: old.libraryInstance)
    // What VLCKit keeps per player rather than per media. Audio and subtitle
    // delays are per input in libVLC 3, so every media starts without them.
    if let volume {
      next.audio?.volume = volume
    }
    let rate = old.rate
    if rate != 1 {
      next.rate = rate
    }
    old.delegate = nil
    old.drawable = nil
    switch renderTarget {
    case let .appKitView(container, _):
      next.drawable = container
    case .texture:
      // The same texture and sink, so the picture on screen stays until the
      // new player draws.
      textureRenderer?.attach(to: next)
    }
    // The old player's stop is not the new media going: its events stop here.
    events?.attach(to: next)
    next.delegate = self
    mediaPlayer = next
    if let look = subtitleLook {
      _ = setSubtitleLook(
        textScale: look.textScale, color: look.color,
        backgroundColor: look.backgroundColor,
        backgroundOpacity: look.backgroundOpacity,
        outlineThickness: look.outlineThickness, raise: look.raise)
    }
    Self.retire(old)
  }

  func dispose() {
    guard !isDisposed else {
      return
    }
    isDisposed = true
    // libVLC stops calling in before anything else goes.
    events?.detach()
    events = nil
    eventChannel.setStreamHandler(nil)
    let player: VLCMediaPlayer = mediaPlayer
    player.delegate = nil
    player.drawable = nil
    // The player draws until retire pauses it; Detach turns any late callback
    // into a no-op (vlc_video_output.cc).
    textureRenderer?.detach()
    textureRenderer = nil
    mediaPlayer = nil
    Self.retire(player)
  }

  func mediaPlayerStateChanged(_ aNotification: Notification) {
    // A notification VLCKit queued before dispose() can still arrive.
    guard !isDisposed else {
      return
    }
    if mediaPlayer.state == .error {
      sendSnapshot(
        errorCode: "playback_error",
        errorDescription: "VLC encountered an error while playing the media."
      )
      return
    }
    sendSnapshot()
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    guard !isDisposed else {
      return
    }
    sendSnapshot()
  }

  private func sendSnapshot(
    force: Bool = false,
    stateOverride: String? = nil,
    errorCode: String? = nil,
    errorDescription: String? = nil
  ) {
    guard !isDisposed else {
      return
    }
    guard eventHandler.isListening else {
      return
    }

    var stateName = stateOverride ?? Self.stateName(mediaPlayer)
    let prebuffer = events?.bufferingProgress ?? -1
    // libVLC says "playing" while it fills its buffer; only the Buffering
    // event says how full it is (one model on every platform, spec 4).
    if stateOverride == nil && stateName == "playing" && prebuffer >= 0 {
      stateName = "buffering"
    }
    let duration = Self.milliseconds(from: mediaPlayer.media?.length)
    let isSeekable = mediaPlayer.isSeekable
    let trackFingerprint = Self.trackFingerprint(mediaPlayer)
    if trackFingerprint != lastTrackFingerprint {
      lastTrackFingerprint = trackFingerprint
      trackRevision += 1
    }
    var event: [String: Any] = [
      "state": stateName,
      "position": Self.milliseconds(from: mediaPlayer.time),
      "duration": duration,
      "positionFraction": Double(mediaPlayer.position),
      "volume": Int(mediaPlayer.audio?.volume ?? 0),
      "playbackSpeed": Double(mediaPlayer.rate),
      "audioDelay": Int(mediaPlayer.currentAudioPlaybackDelay),
      "subtitleDelay": Int(mediaPlayer.currentVideoSubTitleDelay),
      // -1 when there is none / subtitles are off; Dart normalises to null.
      "audioTrack": Int(mediaPlayer.currentAudioTrackIndex),
      "subtitleTrack": Int(mediaPlayer.currentVideoSubTitleIndex),
      "trackRevision": trackRevision,
      "isReady": Self.isReadyState(stateName),
      "isSeekable": isSeekable,
      "isLive": Self.isLiveState(stateName) && duration == 0 && !isSeekable,
    ]
    event["pictureHeld"] = events?.pictureHeld ?? false
    if prebuffer >= 0 {
      event["bufferingProgress"] = prebuffer
    }
    if let events, events.seekRefusals > 0 {
      event["seekRefusals"] = events.seekRefusals
      event["seekRefusedAt"] = events.seekRefusedAt
    }
    if let videoSize = Self.videoSizeMap(mediaPlayer.videoSize) {
      event["videoSize"] = videoSize
    }
    // The texture is the decoder's padded buffer, not the visible picture;
    // Dart clips the difference. Absent for view-backed players, whose
    // drawable already crops.
    if let renderer = textureRenderer,
       let codedSize = Self.videoSizeMap(renderer.codedSize) {
      event["codedSize"] = codedSize
    }
    if let errorDescription {
      event["errorCode"] = errorCode ?? "playback_error"
      event["errorDescription"] = errorDescription
    }
    let snapshot = NSDictionary(dictionary: event)
    if !force, let lastSentEvent = lastSentEvent, lastSentEvent.isEqual(snapshot) {
      return
    }
    lastSentEvent = snapshot
    eventHandler.send(event)
  }

  private static func milliseconds(from time: VLCTime?) -> Int {
    guard let time else {
      return 0
    }
    return max(0, Int(time.intValue))
  }

  private static func videoSizeMap(_ size: CGSize) -> [String: Int]? {
    let width = Int(size.width)
    let height = Int(size.height)
    guard width > 0 && height > 0 else {
      return nil
    }
    return ["width": width, "height": height]
  }

  private static func emptyMediaStats() -> [String: Any] {
    return [
      "available": false,
      "readBytes": 0,
      "inputBitrate": 0.0,
      "demuxReadBytes": 0,
      "demuxBitrate": 0.0,
      "demuxCorrupted": 0,
      "demuxDiscontinuity": 0,
      "decodedVideo": 0,
      "decodedAudio": 0,
      "displayedPictures": 0,
      "lostPictures": 0,
      "playedAudioBuffers": 0,
      "lostAudioBuffers": 0,
      "sentPackets": 0,
      "sentBytes": 0,
      "sendBitrate": 0.0,
    ]
  }

  func setFit(_ fit: String) {
    // A texture-backed player is fitted in Dart, by the widget that owns the
    // Texture, so there is nothing to push down here.
    guard case let .appKitView(container, _) = renderTarget else {
      return
    }
    Self.applyFit(fit, to: container)
  }

  private static func applyFit(_ fit: String, to view: VLCVideoView) {
    view.fillScreen = fit == "cover" || fit == "fill"
  }

  private func trackDescriptions(indexes: [Any]?, names: [Any]?) -> [[String: Any?]] {
    let trackIndexes = indexes as? [NSNumber] ?? []
    let trackNames = names as? [String] ?? []
    return trackIndexes.enumerated().map { offset, index in
      [
        "id": index.intValue,
        "name": offset < trackNames.count ? trackNames[offset] : "",
        "language": nil,
      ]
    }
  }

  /// An order-sensitive FNV-1a fingerprint of the audio + subtitle track set.
  ///
  /// Not a security hash: it only has to make two different track lists land
  /// on two different numbers, and it only ever gets compared against the
  /// previous snapshot's value inside this process.
  private static func trackFingerprint(_ mediaPlayer: VLCMediaPlayer) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func fold(_ byte: UInt8) {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    func fold(indexes: [Any]?, names: [Any]?) {
      let trackIndexes = indexes as? [NSNumber] ?? []
      let trackNames = names as? [String] ?? []
      // A list separator, so an id that moves from the audio list to the
      // subtitle list cannot leave the fingerprint where it was.
      fold(0x1f)
      for (offset, index) in trackIndexes.enumerated() {
        withUnsafeBytes(of: Int32(truncatingIfNeeded: index.intValue)) { bytes in
          for byte in bytes {
            fold(byte)
          }
        }
        if offset < trackNames.count {
          for byte in trackNames[offset].utf8 {
            fold(byte)
          }
        }
        // A record separator, so ("a", "bc") and ("ab", "c") differ.
        fold(0x1e)
      }
    }
    fold(indexes: mediaPlayer.audioTrackIndexes, names: mediaPlayer.audioTrackNames)
    fold(indexes: mediaPlayer.videoSubTitlesIndexes, names: mediaPlayer.videoSubTitlesNames)
    return hash
  }

  private func trackIndexes(_ indexes: [Any]?) -> Set<Int> {
    return Set((indexes as? [NSNumber] ?? []).map(\.intValue))
  }

  private func mediaTracks(_ media: VLCMedia?, matching type: String) -> [[String: Any?]] {
    guard let tracks = media?.tracksInformation as? [[String: Any]] else {
      return []
    }

    return tracks.compactMap { track in
      guard Self.trackType(track[VLCMediaTracksInformationType]) == type else {
        return nil
      }
      var info: [String: Any?] = [
        "type": type,
        "codec": track[VLCMediaTracksInformationCodec],
        "language": track[VLCMediaTracksInformationLanguage],
        "bitrate": track[VLCMediaTracksInformationBitrate],
      ]
      if type == "video" {
        info["width"] = track[VLCMediaTracksInformationVideoWidth]
        info["height"] = track[VLCMediaTracksInformationVideoHeight]
      }
      if type == "audio" {
        info["channels"] = track[VLCMediaTracksInformationAudioChannelsNumber]
        info["sampleRate"] = track[VLCMediaTracksInformationAudioRate]
      }
      return info
    }
  }

  private static func trackType(_ value: Any?) -> String {
    let raw = String(describing: value ?? "").lowercased()
    if raw.contains("video") {
      return "video"
    }
    if raw.contains("audio") {
      return "audio"
    }
    if raw.contains("text") || raw.contains("subtitle") {
      return "subtitle"
    }
    return "unknown"
  }

  private static func stateName(_ player: VLCMediaPlayer) -> String {
    switch player.state {
    case .opening:
      return "opening"
    case .buffering:
      // VLCKit reports .buffering throughout healthy playback, not just while
      // stalled. Reporting it verbatim meant the player never said it was
      // playing - the spinner stuck, and every host feature gated on "playing"
      // (progress, scrobbling, completion, next episode) stopped firing.
      return player.isPlaying ? "playing" : "buffering"
    case .playing:
      return "playing"
    case .paused:
      return "paused"
    case .stopped:
      return "stopped"
    case .ended:
      return "ended"
    case .error:
      return "error"
    default:
      // VLCKit 3.x emits .esAdded during normal startup and whenever an
      // elementary stream appears (track switch, adaptive rendition change).
      // Mapping every unmodelled case to "idle" made isReady flip to false in
      // the middle of playback, so consumers saw the player go not-ready while
      // it was demonstrably playing. Derive from the transport instead, and
      // reserve "idle" for the genuine no-media case.
      if player.media == nil {
        return "idle"
      }
      return player.isPlaying ? "playing" : "opening"
    }
  }

  private static func isReadyState(_ state: String) -> Bool {
    return state == "playing" ||
      state == "paused" ||
      state == "stopped" ||
      state == "ended"
  }

  private static func isLiveState(_ state: String) -> Bool {
    // "buffering" is deliberately excluded. isLive is derived from
    // `duration == 0 && !isSeekable`, and both are trivially true while VLC is
    // still opening the stream — so including buffering made every VOD report
    // isLive for the first frames, long enough for a consumer to hide its seek
    // bar and speed controls and then have to put them back.
    return state == "playing" || state == "paused"
  }

  private static func isValidHeader(name: String, value: String) -> Bool {
    return !name.isEmpty &&
      !name.contains("\r") &&
      !name.contains("\n") &&
      !value.contains("\r") &&
      !value.contains("\n")
  }
}

final class VlcPlayerContainerView: VLCVideoView {
  #if DEBUG
  // Flicker hunt. If these fire while the pointer merely moves over the
  // Flutter chrome, the embedder is re-laying-out the platform view on every
  // overlay change and VLCKit is redrawing black on reshape - a different
  // cause from overlay-surface churn, with a different fix. Filter the
  // console on "VLCVIEW".
  private static var geometryEvents = 0

  private func trace(_ what: String) {
    VlcPlayerContainerView.geometryEvents += 1
    NSLog("VLCVIEW #%d %@ frame=%@ window=%@",
          VlcPlayerContainerView.geometryEvents, what,
          NSStringFromRect(frame), window == nil ? "nil" : "set")
  }

  override func layout() {
    trace("layout")
    super.layout()
  }

  override func setFrameSize(_ newSize: NSSize) {
    trace("setFrameSize \(Int(newSize.width))x\(Int(newSize.height))")
    super.setFrameSize(newSize)
  }

  override func viewDidMoveToWindow() {
    trace("viewDidMoveToWindow")
    super.viewDidMoveToWindow()
  }

  override func viewDidChangeBackingProperties() {
    trace("viewDidChangeBackingProperties")
    super.viewDidChangeBackingProperties()
  }
  #endif
}

final class VlcPlayerEventStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  var onListen: (() -> Void)?
  var isListening: Bool {
    return eventSink != nil
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    onListen?()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  /// Sends [event] at once on the main thread, where every snapshot is made,
  /// so an event sent before a method's answer reaches Dart before it:
  /// setSource's opening snapshot says whether the output holds by the time
  /// setMedia returns (FORK.md 33). From any other thread it goes to main.
  func send(_ event: [String: Any]) {
    if Thread.isMainThread {
      eventSink?(event)
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(event)
    }
  }
}
