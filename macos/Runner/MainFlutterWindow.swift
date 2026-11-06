import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Enforce a sensible minimum content size so the user can't drag the
    // window down to a zero-pixel slit (audit H12). 800×600 covers the
    // smallest layout we ship — sidebar + content row stays usable.
    self.contentMinSize = NSSize(width: 800, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // What the player sizes its read-ahead from (lib/core/providers/device_memory.dart).
    let memoryChannel = FlutterMethodChannel(
      name: "dev.akash.skystream/device_memory",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    memoryChannel.setMethodCallHandler { call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(MainFlutterWindow.memoryReading())
    }

    super.awakeFromNib()
  }

  /// Installed memory, and what macOS can hand this app now: free pages plus
  /// the inactive, purgeable and speculative ones it reclaims on demand.
  private static func memoryReading() -> [String: Any] {
    var reading: [String: Any] = [
      "totalMb": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
      "lowRam": false,
    ]
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    if status == KERN_SUCCESS {
      let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
      reading["freeMb"] = Int(pages * UInt64(vm_kernel_page_size) / 1_048_576)
    }
    return reading
  }
}
