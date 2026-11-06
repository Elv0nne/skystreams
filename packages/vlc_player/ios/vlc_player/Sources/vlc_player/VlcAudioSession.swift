import AVFoundation
import Foundation

/// What the system did to our audio, in terms a player can act on.
enum VlcAudioInterruptionEvent {
  /// A call, an alarm, or another app took audio. Stop making noise.
  case began

  /// The interruption is over and the system advises picking up where we
  /// left off.
  case endedResumable

  /// The interruption is over but resuming is not advised: whatever took the
  /// audio is keeping it.
  case endedNotResumable

  /// The output device went away - headphones unplugged, Bluetooth dropped.
  case deviceLost
}

/// The process-wide `AVAudioSession`, shared by every player.
///
/// There is exactly one audio session per app, so this cannot live on a player:
/// two players tearing down each other's session would leave the surviving one
/// silent. Holders are counted, and the session is given back only when the
/// last one lets go, with `.notifyOthersOnDeactivation` so whatever we
/// interrupted - a podcast, usually - can pick itself up.
///
/// Failures are swallowed throughout, and unlike the Android side a refused
/// activation does not hold playback back. It cannot: iOS refuses to activate
/// a session while a call is up, and then also refuses to route any audio, so
/// there is no noise to leak - whereas Android's focus is a convention that
/// nothing enforces. Blocking here would instead risk stranding a player that
/// never received a `.began` and so will never be told the call is over.
final class VlcAudioSession {
  static let shared = VlcAudioSession()

  private var holders = 0

  private init() {}

  /// Claims the session for movie playback.
  ///
  /// Balanced by [relinquish]. `.playback` is what keeps a film audible with
  /// the ringer switch flicked to silent, and what makes the interruption
  /// notifications arrive at all.
  func acquire() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    holders += 1
    activate()
  }

  /// Re-asserts a session this app already holds.
  ///
  /// iOS deactivates our session for the duration of an interruption, so the
  /// play that follows one has to take it back explicitly - claiming it once
  /// at startup is not enough.
  func activate() {
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  func relinquish() {
    holders = max(0, holders - 1)
    guard holders == 0 else {
      return
    }
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
  }
}

/// Audio-session interruptions and route changes, for one player.
///
/// Reports only; the player decides what playback should do about it.
final class VlcAudioInterruptionObserver: NSObject {
  var onEvent: ((VlcAudioInterruptionEvent) -> Void)?

  override init() {
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  /// Stops reporting. Called from the player's dispose so no event can reach a
  /// torn-down VLC instance.
  func stopObserving() {
    NotificationCenter.default.removeObserver(self)
    onEvent = nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else {
      return
    }

    switch type {
    case .began:
      emit(.began)
    case .ended:
      let rawOptions =
        notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
      emit(options.contains(.shouldResume) ? .endedResumable : .endedNotResumable)
    @unknown default:
      break
    }
  }

  @objc private func handleRouteChange(_ notification: Notification) {
    guard
      let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
      reason == .oldDeviceUnavailable
    else {
      return
    }
    // The iOS half of Android's becoming-noisy broadcast: the headphones the
    // film was playing into are gone, and the speaker is not an acceptable
    // substitute.
    emit(.deviceLost)
  }

  private func emit(_ event: VlcAudioInterruptionEvent) {
    // Notifications arrive on whichever queue the session felt like using;
    // everything downstream touches VLC and the event channel.
    if Thread.isMainThread {
      onEvent?(event)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.onEvent?(event)
      }
    }
  }
}
