import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // For the integration tests: Tab, Escape, Space and clicks, sent through AppKit as a person's would be. They
    // work while the window can't be key (another app in front, the screen locked), unlike the
    // system's own events.
    let keys = FlutterMethodChannel(
      name: "challenge_browser_example/keys", binaryMessenger: flutterViewController.engine.binaryMessenger)
    keys.setMethodCallHandler { [weak self, weak flutterViewController] call, result in
      guard let self, let flutterView = flutterViewController?.view else { return result(nil) }
      switch call.method {
      case "focusFlutter":
        // As a click on Flutter's content would.
        result(self.makeFirstResponder(flutterView))
      case "tab":
        let shift = (call.arguments as? Bool) ?? false
        self.press(keyCode: 48, characters: shift ? "\u{19}" : "\t", shift: shift)
        result(nil)
      case "escape":
        self.press(keyCode: 53, characters: "\u{1b}", shift: false)
        result(nil)
      case "space":
        self.press(keyCode: 49, characters: " ", shift: false)
        result(nil)
      case "click":
        // At [x, y]: logical pixels from the top left of Flutter's view.
        guard let at = call.arguments as? [Double], at.count == 2 else { return result(nil) }
        let y = flutterView.isFlipped ? at[1] : flutterView.bounds.height - at[1]
        self.click(at: flutterView.convert(NSPoint(x: at[0], y: y), to: nil))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  private func press(keyCode: UInt16, characters: String, shift: Bool) {
    // Shift goes down and up as a key of its own, as on a keyboard: Flutter follows modifiers from
    // those events, not from the flags on the key.
    if shift { sendShift(down: true) }
    let flags = shift ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2) : []
    send(.keyDown, keyCode: keyCode, characters: characters, flags: flags)
    send(.keyUp, keyCode: keyCode, characters: characters, flags: flags)
    if shift { sendShift(down: false) }
  }

  /// What the window does with a click while it is the active one: the view under it becomes first
  /// responder and gets the mouse events. An inactive window would only take the click to activate.
  private func click(at point: NSPoint) {
    guard let view = contentView?.superview?.hitTest(point) else { return }
    if view.acceptsFirstResponder { makeFirstResponder(view) }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseDown ? 1 : 0)
      else { return }
      type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
    }
  }

  /// NSEvent can't make a modifier key's event itself; Core Graphics can.
  private func sendShift(down: Bool) {
    guard let shift = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: down) else { return }
    shift.type = .flagsChanged
    // With the left Shift key's own bit (NX_DEVICELSHIFTKEYMASK), which tells which Shift it was.
    shift.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2) : []
    guard let event = NSEvent(cgEvent: shift) else { return }
    sendEvent(event)
  }

  private func send(_ type: NSEvent.EventType, keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) {
    guard
      let event = NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
    else { return }
    sendEvent(event)
  }
}
