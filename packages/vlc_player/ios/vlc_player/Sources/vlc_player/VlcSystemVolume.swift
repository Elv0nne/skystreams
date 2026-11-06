import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// The device's media volume, read, watched and set as VLC's iOS player does
/// it: through the system's own volume control, with the app's audio session
/// taken back first.
///
/// libVLC lets the session go as a film pauses, and while it is inactive iOS
/// neither applies the control's value nor reports the level's changes, so the
/// session is activated before each read and set and as the player shows -
/// never deactivated, and its category never touched. A volume plugin that set
/// the category (`.ambient`, which silent mode mutes) as its listener started,
/// and deactivated the session as it stopped, did both under a playing film:
/// libVLC's audio output went silent, and the player's stop then waited
/// forever on its decoder.
final class VlcSystemVolume: NSObject, FlutterStreamHandler {
  private var observation: NSKeyValueObservation?

  /// Activation blocks on the audio server, so it runs off the main thread, in
  /// order with the reads and sets that need it.
  private static let session = DispatchQueue(label: "vlc_player.audio-session")

  private static func activate() {
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  /// The current level, 0..1, read once the session is active again.
  static func read(_ done: @escaping (Double) -> Void) {
    session.async {
      activate()
      let level = Double(AVAudioSession.sharedInstance().outputVolume)
      DispatchQueue.main.async {
        done(level)
      }
    }
  }

  /// The system's own volume control, kept off screen: setting its slider is how an app sets the device's volume,
  /// and while it is in a window iOS shows no volume pop-up for the hardware buttons.
  private static let control: MPVolumeView = {
    let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    return view
  }()

  /// Sets the level, without the system's pop-up.
  static func setLevel(_ level: Double) {
    let value = Float(min(max(level, 0), 1))
    session.async {
      activate()
      DispatchQueue.main.async {
        control.subviews.compactMap { $0 as? UISlider }.first?.value = value
      }
    }
  }

  /// While the player is shown, iOS shows no volume pop-up for the hardware
  /// buttons (the player draws its own rail) and the session is the app's, so
  /// their changes are reported.
  static func setPlayerShown(_ shown: Bool) {
    if shown {
      session.async {
        activate()
      }
    }
    setSystemUiShown(!shown)
  }

  /// Whether the system's own volume pop-up shows for the hardware buttons: the control goes into the key window, or
  /// out of it.
  static func setSystemUiShown(_ shown: Bool) {
    if shown {
      control.removeFromSuperview()
      return
    }
    guard control.superview == nil, let window = keyWindow() else {
      return
    }
    window.insertSubview(control, at: 0)
  }

  private static func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first(where: { $0.isKeyWindow }) ?? windows.first
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
      guard let level = change.newValue else {
        return
      }
      // Observed on whichever thread the session reports from; the sink is the platform thread's.
      DispatchQueue.main.async {
        events(Double(level))
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    observation?.invalidate()
    observation = nil
    return nil
  }
}
