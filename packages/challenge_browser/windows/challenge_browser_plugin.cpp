#include "challenge_browser_plugin.h"

#include <WebView2EnvironmentOptions.h>
#include <commctrl.h>
#include <shlobj.h>
#include <windows.h>

#include <filesystem>

namespace challenge_browser {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

// The browser's own data, cookies included: under the user's local app data, named for the app.
// The default, next to the executable, isn't writable in Program Files.
std::wstring UserDataFolder() {
  PWSTR local = nullptr;
  std::filesystem::path folder;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) folder = local;
  CoTaskMemFree(local);
  wchar_t executable[MAX_PATH];
  GetModuleFileNameW(nullptr, executable, MAX_PATH);
  return (folder / std::filesystem::path(executable).stem() / L"WebView2").wstring();
}

FlutterError NoPage(int64_t page_id) {
  return FlutterError("no-page", "No page " + std::to_string(page_id));
}

// Makes the pages inside Flutter's view count as part of it for keyboard focus, as platform views
// would.
LRESULT CALLBACK KeepViewFocus(HWND view, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR) {
  switch (message) {
    case WM_KILLFOCUS:
    case WM_SETFOCUS:
      // Focus moving between the view and a page in it (wparam: the window gaining focus, or losing
      // it). Flutter would count the view as unfocused and park its own focus, then take the keys
      // back from the page as soon as its focus moved again.
      if (wparam && IsChild(view, reinterpret_cast<HWND>(wparam))) return 0;
      break;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_XBUTTONDOWN:
    case WM_POINTERDOWN: {
      // Flutter's view doesn't take focus when pressed: a press on its content takes the keys back
      // from a page.
      const HWND focused = GetFocus();
      if (focused && IsChild(view, focused)) SetFocus(view);
      break;
    }
  }
  return DefSubclassProc(view, message, wparam, lparam);
}

}  // namespace

void ChallengeBrowserPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<ChallengeBrowserPlugin>(registrar);
  PageHostApi::SetUp(registrar->messenger(), plugin.get());
  registrar->AddPlugin(std::move(plugin));
}

ChallengeBrowserPlugin::ChallengeBrowserPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), events_(registrar->messenger()) {
  window_proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
        if (message == WM_MOVE || message == WM_MOVING) {
          for (const auto& [id, page] : pages_) page->ParentMoved();
        }
        return std::nullopt;
      });
}

ChallengeBrowserPlugin::~ChallengeBrowserPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  if (view_) RemoveWindowSubclass(view_, KeepViewFocus, 0);
}

void ChallengeBrowserPlugin::Create(const std::string& script_channel, std::function<void(ErrorOr<int64_t> reply)> result) {
  // WebView2 needs no channel name: a page posts with window.chrome.webview.postMessage.
  flutter::FlutterView* view = registrar_->GetView();
  if (!view) return result(FlutterError("no-view", "Flutter's view has no window"));
  const HWND parent = view->GetNativeWindow();
  if (view_ != parent) {
    view_ = parent;
    SetWindowSubclass(view_, KeepViewFocus, 0, 0);
  }
  WithEnvironment([this, parent, result](ComPtr<ICoreWebView2Environment> environment, HRESULT ready) {
    // Most likely no WebView2 runtime is installed.
    if (FAILED(ready)) return result(Failure("no-webview2", ready));
    const HRESULT started = environment->CreateCoreWebView2Controller(
        parent, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [this, environment, parent, result](HRESULT error, ICoreWebView2Controller* controller) -> HRESULT {
                      if (FAILED(error)) {
                        result(Failure("create", error));
                        return S_OK;
                      }
                      const int64_t id = ++next_id_;
                      pages_[id] = std::make_unique<Page>(
                          environment, controller, parent,
                          [this, id](const PageEvent& event) { events_.OnEvent(id, event, [] {}, [](const FlutterError&) {}); });
                      result(id);
                      return S_OK;
                    })
                    .Get());
    if (FAILED(started)) result(Failure("create", started));
  });
}

std::optional<FlutterError> ChallengeBrowserPlugin::Load(int64_t page_id,
                                                         const std::string& url,
                                                         const flutter::EncodableMap& headers) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  return page->Load(url, headers);
}

void ChallengeBrowserPlugin::Evaluate(int64_t page_id,
                                      const std::string& script,
                                      std::function<void(ErrorOr<std::string> reply)> result) {
  Page* page = Find(page_id);
  if (!page) return result(NoPage(page_id));
  page->Evaluate(script, std::move(result));
}

std::optional<FlutterError> ChallengeBrowserPlugin::AddDocumentStartScript(int64_t page_id, const std::string& script) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  page->AddDocumentStartScript(script);
  return std::nullopt;
}

void ChallengeBrowserPlugin::Cookies(int64_t page_id,
                                     const std::string& url,
                                     std::function<void(ErrorOr<flutter::EncodableList> reply)> result) {
  Page* page = Find(page_id);
  if (!page) return result(NoPage(page_id));
  page->Cookies(url, std::move(result));
}

void ChallengeBrowserPlugin::DeleteCookies(int64_t page_id,
                                           const std::string& url,
                                           const std::string* name,
                                           std::function<void(std::optional<FlutterError> reply)> result) {
  Page* page = Find(page_id);
  if (!page) return result(NoPage(page_id));
  page->DeleteCookies(url, name, std::move(result));
}

void ChallengeBrowserPlugin::UserAgent(int64_t page_id, std::function<void(ErrorOr<std::string> reply)> result) {
  Page* page = Find(page_id);
  if (!page) return result(NoPage(page_id));
  result(page->UserAgent());
}

std::optional<FlutterError> ChallengeBrowserPlugin::SetUserAgent(int64_t page_id, const std::string& user_agent) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  return page->SetUserAgent(user_agent);
}

std::optional<FlutterError> ChallengeBrowserPlugin::SetCapture(int64_t page_id, bool enabled) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  page->SetCapture(enabled);
  return std::nullopt;
}

std::optional<FlutterError> ChallengeBrowserPlugin::SetFrame(int64_t page_id, const PageFrame* frame) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  page->SetFrame(frame);
  return std::nullopt;
}

std::optional<FlutterError> ChallengeBrowserPlugin::Focus(int64_t page_id, bool forward) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  page->Focus(forward);
  return std::nullopt;
}

std::optional<FlutterError> ChallengeBrowserPlugin::Blur(int64_t page_id) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  page->Blur();
  return std::nullopt;
}

std::optional<FlutterError> ChallengeBrowserPlugin::SetNavigationStops(int64_t page_id,
                                                                       const flutter::EncodableList& prefixes) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  std::vector<std::string> stops;
  for (const auto& prefix : prefixes) {
    if (const auto* text = std::get_if<std::string>(&prefix)) stops.push_back(*text);
  }
  page->SetNavigationStops(std::move(stops));
  return std::nullopt;
}

void ChallengeBrowserPlugin::Dispose(int64_t page_id, std::function<void(std::optional<FlutterError> reply)> result) {
  pages_.erase(page_id);
  result(std::nullopt);
}

void ChallengeBrowserPlugin::Tap(int64_t page_id, double x, double y,
                                 std::function<void(std::optional<FlutterError> reply)> result) {
  Page* page = Find(page_id);
  if (!page) return result(NoPage(page_id));
  page->Tap(x, y, std::move(result));
}

void ChallengeBrowserPlugin::EvaluateIsolated(int64_t page_id,
                                              const std::string& script,
                                              std::function<void(ErrorOr<std::string> reply)> result) {
  // Dart builds Windows' isolated world over DevTools instead.
  result(FlutterError("unsupported", "Windows uses DevTools for isolated worlds"));
}

ErrorOr<PageCapabilities> ChallengeBrowserPlugin::Capabilities() { return PageCapabilities(true, true); }

ErrorOr<std::string> ChallengeBrowserPlugin::EngineVersion() { return std::string(); }

void ChallengeBrowserPlugin::DevTools(int64_t page_id,
                                      const std::string& method,
                                      const std::string& params_json,
                                      std::function<void(ErrorOr<std::string> reply)> result) {
  Page* page = Find(page_id);
  if (!page) return result(NoPage(page_id));
  page->DevTools(method, params_json, std::move(result));
}

ErrorOr<std::string> ChallengeBrowserPlugin::ServeFolder(int64_t page_id, const std::string& name,
                                                          const std::string& folder) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  return page->ServeFolder(name, folder);
}

std::optional<FlutterError> ChallengeBrowserPlugin::HoldDialogs(int64_t page_id, bool hold) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  page->HoldDialogs(hold);
  return std::nullopt;
}

std::optional<FlutterError> ChallengeBrowserPlugin::AnswerDialog(int64_t page_id,
                                                                 int64_t dialog_id,
                                                                 bool accept,
                                                                 const std::string* text) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  page->AnswerDialog(dialog_id, accept, text);
  return std::nullopt;
}

ErrorOr<std::optional<std::string>> ChallengeBrowserPlugin::Title(int64_t page_id) {
  Page* page = Find(page_id);
  if (!page) return NoPage(page_id);
  return page->Title();
}

void ChallengeBrowserPlugin::WithEnvironment(EnvironmentReady ready) {
  if (environment_) return ready(environment_, S_OK);
  waiting_.push_back(std::move(ready));
  // Already on its way.
  if (waiting_.size() > 1) return;
  const auto finish = [this](HRESULT result) {
    const std::vector<EnvironmentReady> waiting = std::move(waiting_);
    waiting_.clear();
    for (const EnvironmentReady& then : waiting) then(environment_, result);
  };
  // English everywhere: the language sites read (Accept-Language and navigator.language), and the
  // browser's own words. Cloudflare's checks then read and lay out the same on every device.
  auto options = Microsoft::WRL::Make<CoreWebView2EnvironmentOptions>();
  options->put_Language(L"en-US");
  const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, UserDataFolder().c_str(), options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this, finish](HRESULT result, ICoreWebView2Environment* environment) -> HRESULT {
            if (SUCCEEDED(result)) environment_ = environment;
            finish(result);
            return S_OK;
          })
          .Get());
  if (FAILED(started)) finish(started);
}

Page* ChallengeBrowserPlugin::Find(int64_t page_id) {
  const auto found = pages_.find(page_id);
  return found == pages_.end() ? nullptr : found->second.get();
}

}  // namespace challenge_browser
