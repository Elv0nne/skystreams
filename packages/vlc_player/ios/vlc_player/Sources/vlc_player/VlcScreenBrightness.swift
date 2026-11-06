import UIKit

/// The app's screen brightness on iOS, where one brightness serves the whole
/// device, as VLC for iOS's player keeps it.
///
/// - A drag sets the level directly on every update, with no animation, so
///   the screen follows the finger.
/// - The system's level is kept from the first set, and given back with a
///   short fade on [reset] (the player closing) and as the app is about to go
///   inactive (Control Center, the app switcher, the lock): an app can't set
///   the brightness once it has left the foreground (Apple's QA1751).
/// - Back in the foreground, the app's level comes back, unless the person
///   changed the brightness meanwhile: then theirs stands, and becomes the
///   system's level to give back later.
final class VlcScreenBrightness {
  static let shared = VlcScreenBrightness()

  /// The device's level before the app set its own; nil while it has none.
  private var system: CGFloat?
  /// The app's own level, while it has one.
  private var applied: CGFloat?
  /// Bumped by every change, so a fade still running is abandoned.
  private var generation = 0
  private var observers: [NSObjectProtocol] = []

  private init() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in self?.giveBack()
      })
    observers.append(
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
        [weak self] _ in self?.takeBack()
      })
  }

  /// The screen of the app's active window scene, as VLC's player takes it (iPad multitasking).
  private var screen: UIScreen {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive })?.screen
      ?? scenes.first?.screen
      ?? UIScreen.main
  }

  /// The level the screen shows now.
  func level() -> Double {
    return Double(screen.brightness)
  }

  /// Sets the app's level, at once.
  func set(_ level: Double) {
    if system == nil {
      system = screen.brightness
    }
    let value = CGFloat(min(max(level, 0), 1))
    applied = value
    generation += 1
    screen.brightness = value
  }

  /// Gives the screen back to the system's level.
  func reset() {
    applied = nil
    guard let system = system else {
      return
    }
    self.system = nil
    fade(to: system)
  }

  private func giveBack() {
    guard applied != nil, let system = system else {
      return
    }
    // Directly: the app is about to lose the foreground, and a fade might not finish in it.
    generation += 1
    screen.brightness = system
  }

  private func takeBack() {
    guard let applied = applied, let system = system else {
      return
    }
    // Changed while the app was away (Control Center): the person's level stands.
    if abs(screen.brightness - system) > 0.03 {
      self.system = screen.brightness
      self.applied = nil
      return
    }
    fade(to: applied)
  }

  /// A short fade, on the main queue: about 0.3 s in 12 steps. A newer change ends it.
  private func fade(to target: CGFloat) {
    generation += 1
    let run = generation
    let start = screen.brightness
    let steps = 12
    for step in 1...steps {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.025 * Double(step)) { [weak self] in
        guard let self = self, self.generation == run else {
          return
        }
        self.screen.brightness = start + (target - start) * CGFloat(step) / CGFloat(steps)
      }
    }
  }
}
