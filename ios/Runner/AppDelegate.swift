import Flutter
import os
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var downloadContinuedProcessingChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Only the delegate is installed here. Authorisation is deliberately NOT
    // requested at launch: the app posts no notification until a download
    // exists, so a cold-start prompt has no context, and it is the single most
    // common reason a user denies notifications permanently. The request is
    // raised in-context by DownloadService.ensureNotificationPermission when
    // the first download actually starts.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // This is required to show notifications while the app is in the foreground
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "dev.akash.skystream/download_continued_processing",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )

    channel.setMethodCallHandler { call, result in
#if os(iOS)
      guard #available(iOS 26.0, *) else {
        result(false)
        return
      }

      guard let arguments = call.arguments as? [String: Any],
            let taskId = arguments["taskId"] as? String else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "taskId is required",
            details: nil
          )
        )
        return
      }

      Task { @MainActor in
        do {
          let manager = DownloadContinuedProcessingManager.shared

          switch call.method {
          case "start":
            guard let displayName = arguments["displayName"] as? String else {
              result(
                FlutterError(
                  code: "INVALID_ARGUMENTS",
                  message: "displayName is required",
                  details: nil
                )
              )
              return
            }

            let progress =
              (arguments["progress"] as? NSNumber)?.doubleValue ?? 0.0
            let totalBytes =
              (arguments["totalBytes"] as? NSNumber)?.int64Value ?? -1

            let identifier = try manager.start(
              taskId: taskId,
              displayName: displayName,
              progress: progress,
              totalBytes: totalBytes
            )
            if let identifier {
              result(identifier)
            } else {
              result(false)
            }

          case "update":
            let progress =
              (arguments["progress"] as? NSNumber)?.doubleValue ?? 0.0
            let totalBytes =
              (arguments["totalBytes"] as? NSNumber)?.int64Value ?? -1
            manager.update(
              taskId: taskId,
              progress: progress,
              totalBytes: totalBytes
            )
            result(true)

          case "finish":
            let success = arguments["success"] as? Bool ?? false
            let status = arguments["status"] as? String ?? "failed"
            manager.finish(
              taskId: taskId,
              success: success,
              status: status
            )
            result(true)

          case "stop":
            manager.stop(taskId: taskId)
            result(true)

          default:
            result(FlutterMethodNotImplemented)
          }
        } catch {
          result(
            FlutterError(
              code: "CONTINUED_PROCESSING_ERROR",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
#else
      result(false)
#endif
    }

#if os(iOS)
    if #available(iOS 26.0, *) {
      DownloadContinuedProcessingManager.shared.cancellationHandler = {
        [weak channel] taskId in
        channel?.invokeMethod(
          "cancel",
          arguments: ["taskId": taskId]
        )
      }
    }
#endif

    downloadContinuedProcessingChannel = channel

    // The player turns a handset to fit the video and lets go on the way out,
    // but iOS keeps a turned interface for as long as it is still allowed: the
    // app stayed sideways in an upright hand, and for good under the rotation
    // lock. The player asks here for the device's own orientation, which UIKit
    // reports with the lock applied.
    let orientationChannel = FlutterMethodChannel(
      name: "dev.akash.skystream/orientation",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    orientationChannel.setMethodCallHandler { call, result in
      guard call.method == "followDevice" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let fallback = (call.arguments as? [String: Any])?["fallback"] as? String
      // A turn of the main queue later, after the engine has applied the
      // release the player sent first.
      DispatchQueue.main.async {
        AppDelegate.followDeviceOrientation(fallback: fallback)
        result(nil)
      }
    }

    // What the player sizes its read-ahead from (lib/core/providers/device_memory.dart).
    let memoryChannel = FlutterMethodChannel(
      name: "dev.akash.skystream/device_memory",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    memoryChannel.setMethodCallHandler { call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      var reading: [String: Any] = [
        "totalMb": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
        "lowRam": false,
      ]
      // What this app may still allocate before iOS ends it: what a buffer
      // competes for. The simulator has no such limit and reports 0.
      let available = os_proc_available_memory()
      if available > 0 {
        reading["freeMb"] = Int(available / 1_048_576)
      }
      result(reading)
    }
  }

  /// Turns the app to the device's orientation. Face up, face down, or no
  /// reading at all (a simulator has no accelerometer) turns it to `fallback`
  /// instead, the way it was before the player turned it.
  private static func followDeviceOrientation(fallback: String?) {
    guard #available(iOS 16.0, *) else {
      UIViewController.attemptRotationToDeviceOrientation()
      return
    }
    let mask: UIInterfaceOrientationMask
    switch UIDevice.current.orientation {
    case .portrait: mask = .portrait
    case .portraitUpsideDown: mask = .portraitUpsideDown
    // A device turned left shows its interface turned right.
    case .landscapeLeft: mask = .landscapeRight
    case .landscapeRight: mask = .landscapeLeft
    default:
      switch fallback {
      case "portrait": mask = .portrait
      case "landscape": mask = .landscape
      default: return
      }
    }
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
  }
}
