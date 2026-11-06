import Foundation
import WebKit

/// A page's served folders (Phase 7c's §6): `cbfolder://<name>/<path>` is the file at <path> in the folder served under
/// <name>, read-only; nothing outside a folder is served. WebKit asks on the main thread; a file is read off it (a game's
/// is up to 16 MB) and answered back on it.
@MainActor
final class FolderServer: NSObject, WKURLSchemeHandler {
  static let scheme = "cbfolder"

  private var folders: [String: URL] = [:]

  /// Tasks WebKit stopped while their file was being read: answering one would raise.
  private var stopped = Set<ObjectIdentifier>()

  /// Serves [folder] under [name], in place of what that name served, and returns the address's base.
  func serve(_ name: String, folder: String) -> String {
    let name = name.lowercased()
    folders[name] = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
    return "\(FolderServer.scheme)://\(name)/"
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url, let name = url.host?.lowercased(), let root = folders[name],
      let file = FolderServer.file(url.path, in: root)
    else {
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    let id = ObjectIdentifier(task)
    DispatchQueue.global(qos: .userInitiated).async {
      let data = try? Data(contentsOf: file, options: .mappedIfSafe)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if self.stopped.remove(id) != nil { return }
          guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
          }
          let headers = ["Content-Type": FolderServer.type(file.pathExtension), "Content-Length": String(data.count)]
          task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
          task.didReceive(data)
          task.didFinish()
        }
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    stopped.insert(ObjectIdentifier(task))
  }

  /// The file at [path] (an address's path, decoded) in [root]: nil when it leaves the folder or names no file.
  private static func file(_ path: String, in root: URL) -> URL? {
    let base = root.resolvingSymlinksInPath().path
    let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    var directory: ObjCBool = false
    guard file.path.hasPrefix(base + "/"),
      FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue
    else { return nil }
    return file
  }

  /// A served file's type, by its extension: what a page's own scripts, styles and media need.
  private static func type(_ ext: String) -> String {
    switch ext.lowercased() {
    case "html", "htm": return "text/html"
    case "js", "mjs": return "text/javascript"
    case "css": return "text/css"
    case "json": return "application/json"
    case "wasm": return "application/wasm"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "mp3": return "audio/mpeg"
    case "ogg": return "audio/ogg"
    case "wav": return "audio/wav"
    case "mp4": return "video/mp4"
    case "txt": return "text/plain"
    default: return "application/octet-stream"
    }
  }
}
