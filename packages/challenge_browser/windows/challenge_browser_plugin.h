#ifndef FLUTTER_PLUGIN_CHALLENGE_BROWSER_PLUGIN_H_
#define FLUTTER_PLUGIN_CHALLENGE_BROWSER_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <functional>
#include <map>
#include <memory>
#include <vector>

#include "messages.g.h"
#include "page.h"

namespace challenge_browser {

// Runs each `ChallengeBrowser` page in a WebView2 of its own. Pages share one WebView2 environment,
// so one browser process and one cookie store.
class ChallengeBrowserPlugin : public flutter::Plugin, public PageHostApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit ChallengeBrowserPlugin(flutter::PluginRegistrarWindows* registrar);
  ~ChallengeBrowserPlugin() override;

  ChallengeBrowserPlugin(const ChallengeBrowserPlugin&) = delete;
  ChallengeBrowserPlugin& operator=(const ChallengeBrowserPlugin&) = delete;

  void Create(const std::string& script_channel, std::function<void(ErrorOr<int64_t> reply)> result) override;
  std::optional<FlutterError> Load(int64_t page_id,
                                   const std::string& url,
                                   const flutter::EncodableMap& headers) override;
  void Evaluate(int64_t page_id,
                const std::string& script,
                std::function<void(ErrorOr<std::string> reply)> result) override;
  std::optional<FlutterError> AddDocumentStartScript(int64_t page_id, const std::string& script) override;
  void Cookies(int64_t page_id,
               const std::string& url,
               std::function<void(ErrorOr<flutter::EncodableList> reply)> result) override;
  void DeleteCookies(int64_t page_id,
                     const std::string& url,
                     const std::string* name,
                     std::function<void(std::optional<FlutterError> reply)> result) override;
  void UserAgent(int64_t page_id, std::function<void(ErrorOr<std::string> reply)> result) override;
  std::optional<FlutterError> SetUserAgent(int64_t page_id, const std::string& user_agent) override;
  std::optional<FlutterError> SetCapture(int64_t page_id, bool enabled) override;
  std::optional<FlutterError> SetFrame(int64_t page_id, const PageFrame* frame) override;
  std::optional<FlutterError> Focus(int64_t page_id, bool forward) override;
  std::optional<FlutterError> Blur(int64_t page_id) override;
  std::optional<FlutterError> SetNavigationStops(int64_t page_id,
                                                 const flutter::EncodableList& prefixes) override;
  void Dispose(int64_t page_id, std::function<void(std::optional<FlutterError> reply)> result) override;
  void Tap(int64_t page_id, double x, double y, std::function<void(std::optional<FlutterError> reply)> result) override;
  void EvaluateIsolated(int64_t page_id,
                        const std::string& script,
                        std::function<void(ErrorOr<std::string> reply)> result) override;
  ErrorOr<PageCapabilities> Capabilities() override;
  ErrorOr<std::string> EngineVersion() override;
  void DevTools(int64_t page_id,
                const std::string& method,
                const std::string& params_json,
                std::function<void(ErrorOr<std::string> reply)> result) override;
  ErrorOr<std::string> ServeFolder(int64_t page_id, const std::string& name, const std::string& folder) override;
  std::optional<FlutterError> HoldDialogs(int64_t page_id, bool hold) override;
  std::optional<FlutterError> AnswerDialog(int64_t page_id,
                                           int64_t dialog_id,
                                           bool accept,
                                           const std::string* text) override;
  ErrorOr<std::optional<std::string>> Title(int64_t page_id) override;

 private:
  using EnvironmentReady = std::function<void(Microsoft::WRL::ComPtr<ICoreWebView2Environment>, HRESULT)>;

  // Creates the shared environment the first time, then hands it to [ready].
  void WithEnvironment(EnvironmentReady ready);

  Page* Find(int64_t page_id);

  flutter::PluginRegistrarWindows* registrar_;
  PageFlutterApi events_;

  // Flutter's view, once a page is in it.
  HWND view_ = nullptr;
  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment_;
  std::vector<EnvironmentReady> waiting_;
  std::map<int64_t, std::unique_ptr<Page>> pages_;
  int64_t next_id_ = 0;
  int window_proc_id_ = -1;
};

}  // namespace challenge_browser

#endif  // FLUTTER_PLUGIN_CHALLENGE_BROWSER_PLUGIN_H_
