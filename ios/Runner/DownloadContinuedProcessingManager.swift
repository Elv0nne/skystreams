#if os(iOS)
import BackgroundTasks
import Foundation
import UIKit

@available(iOS 26.0, *)
private enum DownloadContinuedProcessingError: LocalizedError {
  case registrationRejected(String)

  var errorDescription: String? {
    switch self {
    case .registrationRejected(let identifier):
      return "BGTaskScheduler rejected registration for \(identifier)."
    }
  }
}

/// Owns iOS 26 BGContinuedProcessingTask instances for downloads.
///
/// The system, not SkyStream, renders the Dynamic Island and Lock Screen UI.
/// background_downloader remains responsible for the actual URLSession
/// transfer; this class only supplies system progress and cancellation.
@available(iOS 26.0, *)
@MainActor
final class DownloadContinuedProcessingManager {
  static let shared = DownloadContinuedProcessingManager()

  struct Snapshot {
    var displayName: String
    var progress: Double
    var totalBytes: Int64
  }

  var cancellationHandler: ((String) -> Void)?

  private let scheduler = BGTaskScheduler.shared
  private var activeTasks: [String: BGContinuedProcessingTask] = [:]
  private var snapshots: [String: Snapshot] = [:]
  private var identifiers: [String: String] = [:]
  private var registeredIdentifiers = Set<String>()

  private init() {}

  func start(
    taskId: String,
    displayName: String,
    progress: Double,
    totalBytes: Int64
  ) throws -> String? {
    // Apple requires submission to originate from an explicit foreground
    // action. A restored automatic download therefore keeps using the normal
    // URLSession path without creating unexpected system UI.
    guard UIApplication.shared.applicationState == .active else {
      return nil
    }

    let normalized = min(max(progress, 0.0), 1.0)
    let snapshot = Snapshot(
      displayName: displayName,
      progress: normalized,
      totalBytes: totalBytes
    )
    snapshots[taskId] = snapshot

    if let active = activeTasks[taskId] {
      apply(snapshot, to: active)
      return identifiers[taskId]
    }

    let identifier = identifiers[taskId] ?? taskIdentifier(for: taskId)
    identifiers[taskId] = identifier

    if !registeredIdentifiers.contains(identifier) {
      let accepted = scheduler.register(
        forTaskWithIdentifier: identifier,
        using: DispatchQueue.main
      ) { [weak self] task in
        guard let continuedTask = task as? BGContinuedProcessingTask else {
          task.setTaskCompleted(success: false)
          return
        }

        Task { @MainActor in
          self?.attach(continuedTask, taskId: taskId)
        }
      }

      guard accepted else {
        throw DownloadContinuedProcessingError.registrationRejected(identifier)
      }
      registeredIdentifiers.insert(identifier)
    }

    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: title(for: displayName),
      subtitle: subtitle(for: snapshot)
    )
    request.strategy = .queue
    try scheduler.submit(request)
    return identifier
  }

  func update(taskId: String, progress: Double, totalBytes: Int64) {
    guard var snapshot = snapshots[taskId] else { return }

    snapshot.progress = min(max(progress, 0.0), 1.0)
    if totalBytes > 0 {
      snapshot.totalBytes = totalBytes
    }
    snapshots[taskId] = snapshot

    if let task = activeTasks[taskId] {
      apply(snapshot, to: task)
    }
  }

  func finish(taskId: String, success: Bool, status: String) {
    cancelPendingRequest(for: taskId)

    if let task = activeTasks.removeValue(forKey: taskId) {
      let snapshot = snapshots[taskId]
      if success {
        if task.progress.totalUnitCount <= 0 {
          task.progress.totalUnitCount = 1000
        }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle(
          "Download complete",
          subtitle: snapshot?.displayName ?? ""
        )
      } else if status == "failed" {
        task.updateTitle(
          "Download failed",
          subtitle: snapshot?.displayName ?? ""
        )
      }
      task.expirationHandler = nil
      task.setTaskCompleted(success: success)
    }

    snapshots.removeValue(forKey: taskId)
    identifiers.removeValue(forKey: taskId)
  }

  func stop(taskId: String) {
    cancelPendingRequest(for: taskId)

    if let task = activeTasks.removeValue(forKey: taskId) {
      task.expirationHandler = nil
      task.setTaskCompleted(success: false)
    }

    snapshots.removeValue(forKey: taskId)
    identifiers.removeValue(forKey: taskId)
  }

  private func attach(
    _ task: BGContinuedProcessingTask,
    taskId: String
  ) {
    activeTasks[taskId] = task

    task.expirationHandler = { [weak self, weak task] in
      Task { @MainActor in
        guard let self else { return }
        self.cancellationHandler?(taskId)
        task?.setTaskCompleted(success: false)
        self.activeTasks.removeValue(forKey: taskId)
        self.snapshots.removeValue(forKey: taskId)
        self.identifiers.removeValue(forKey: taskId)
      }
    }

    if let snapshot = snapshots[taskId] {
      apply(snapshot, to: task)
    } else {
      task.progress.totalUnitCount = 1000
      task.progress.completedUnitCount = 0
    }
  }

  private func apply(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask
  ) {
    let normalized = min(max(snapshot.progress, 0.0), 1.0)

    if snapshot.totalBytes > 0 {
      task.progress.totalUnitCount = snapshot.totalBytes
      let completed = Int64(
        (Double(snapshot.totalBytes) * normalized).rounded(.down)
      )
      task.progress.completedUnitCount = min(
        max(completed, 0),
        snapshot.totalBytes
      )
    } else {
      task.progress.totalUnitCount = 1000
      task.progress.completedUnitCount = Int64(
        (normalized * 1000.0).rounded(.down)
      )
    }

    task.updateTitle(
      title(for: snapshot.displayName),
      subtitle: subtitle(for: snapshot)
    )
  }

  private func cancelPendingRequest(for taskId: String) {
    guard let identifier = identifiers[taskId] else { return }
    scheduler.cancel(taskRequestWithIdentifier: identifier)
  }

  private func taskIdentifier(for taskId: String) -> String {
    let bundleId = Bundle.main.bundleIdentifier ?? "dev.akash.skystream"
    let safeSuffix = taskId.replacingOccurrences(
      of: "[^A-Za-z0-9_-]",
      with: "-",
      options: .regularExpression
    )
    let suffix = safeSuffix.isEmpty
      ? UUID().uuidString
      : String(safeSuffix.prefix(80))
    return "\(bundleId).download.\(suffix)"
  }

  private func title(for displayName: String) -> String {
    "Downloading “\(displayName)”"
  }

  private func subtitle(for snapshot: Snapshot) -> String {
    guard snapshot.totalBytes > 0 else {
      return "\(Int((snapshot.progress * 100.0).rounded()))% complete"
    }

    let downloaded = Int64(
      (Double(snapshot.totalBytes) * snapshot.progress).rounded(.down)
    )
    return "\(format(bytes: downloaded)) of \(format(bytes: snapshot.totalBytes))"
  }

  private func format(bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: max(bytes, 0))
  }
}
#endif
