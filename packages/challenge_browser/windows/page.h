#ifndef FLUTTER_PLUGIN_CHALLENGE_BROWSER_PAGE_H_
#define FLUTTER_PLUGIN_CHALLENGE_BROWSER_PAGE_H_

#include <windows.h>
#include <wrl.h>

#include <WebView2.h>

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "messages.g.h"

namespace challenge_browser {

std::wstring Utf16(const std::string& text);
std::string Utf8(const wchar_t* text);

// An error for Dart, from a failed WebView2 call.
FlutterError Failure(const std::string& code, HRESULT result);

// One page: a WebView2 controller of its own, in a child window of Flutter's view. Flutter on
// Windows has no platform views, so a shown page covers the rectangle `ChallengeBrowserView`
// takes, and a hidden one waits outside the view, at a usual size, running as if shown.
class Page {
 public:
  Page(Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment,
       Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller,
       HWND flutter_view,
       std::function<void(const PageEvent&)> emit);
  ~Page();

  Page(const Page&) = delete;
  Page& operator=(const Page&) = delete;

  std::optional<FlutterError> Load(const std::string& url,
                                   const flutter::EncodableMap& headers);
  void Evaluate(const std::string& script,
                std::function<void(ErrorOr<std::string>)> result);
  void AddDocumentStartScript(const std::string& script);
  void Cookies(const std::string& url,
               std::function<void(ErrorOr<flutter::EncodableList>)> result);
  void DeleteCookies(const std::string& url,
                     const std::string* name,
                     std::function<void(std::optional<FlutterError>)> result);
  ErrorOr<std::string> UserAgent();
  std::optional<FlutterError> SetUserAgent(const std::string& agent);
  void SetCapture(bool enabled);

  // Main-frame URLs starting with one of [prefixes] are stopped and reported, not loaded.
  void SetNavigationStops(std::vector<std::string> prefixes) { navigation_stops_ = std::move(prefixes); }

  // Serves [folder] read-only at https://[name].example/ (Phase 7c's §6) and returns that base. Only this page's
  // WebView maps the name.
  ErrorOr<std::string> ServeFolder(const std::string& name, const std::string& folder);

  // Holds the page's dialogs while [hold], reporting each, until AnswerDialog; else WebView2 shows its own.
  void HoldDialogs(bool hold);

  // Answers held dialog [id]: a confirm [accept]s, a prompt answers [text] when [accept], else null.
  void AnswerDialog(int64_t id, bool accept, const std::string* text);

  // The page's title as WebView2 has it (an untitled page's address): nothing runs in the page, which may be waiting
  // in a held dialog.
  ErrorOr<std::optional<std::string>> Title();

  // Shows the page over [frame], in logical pixels from the top left of Flutter's view, or hides
  // it again when [frame] is null.
  void SetFrame(const PageFrame* frame);

  // Moves keyboard focus into the page: to its first control, or its last when going back.
  void Focus(bool forward);

  // Gives keyboard focus back to Flutter's view, if the page has it.
  void Blur();

  // Tells WebView2 the app window moved, so its pop-ups (a select's list) open in the right place.
  void ParentMoved();

  // A click at [x], [y] CSS pixels, as DevTools input: a short move there, then a press and a release,
  // a frame apart. The page needn't be shown or focused. [done] runs when it has been sent.
  void Tap(double x, double y, std::function<void(std::optional<FlutterError>)> done);

  // A DevTools call: [params_json] in, its result JSON out, as WebView2 gives it.
  void DevTools(const std::string& method,
                const std::string& params_json,
                std::function<void(ErrorOr<std::string>)> result);

 private:
  // Gives keyboard focus back to Flutter's view.
  void ReturnKeys();

  // Hidden pages are drawn at scale 1, so they lay out at 1024×768 CSS pixels at any display scale,
  // as on every other platform; shown ones follow the monitor's scale, to stay sharp.
  void FollowMonitorScale(bool follow);

  Microsoft::WRL::ComPtr<ICoreWebView2CookieManager> CookieManager();

  Microsoft::WRL::ComPtr<ICoreWebView2Environment> environment_;
  Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
  Microsoft::WRL::ComPtr<ICoreWebView2> webview_;
  HWND flutter_view_;
  std::function<void(const PageEvent&)> emit_;
  bool shown_ = false;
  bool focused_ = false;
  bool capturing_ = false;
  std::vector<std::string> navigation_stops_;

  // A focus request that came before the page was shown: forward or backward.
  std::optional<bool> pending_focus_;

  // A dialog the page waits on, until Dart answers it.
  struct HeldDialog {
    Microsoft::WRL::ComPtr<ICoreWebView2ScriptDialogOpeningEventArgs> args;
    Microsoft::WRL::ComPtr<ICoreWebView2Deferral> deferral;
  };
  std::map<int64_t, HeldDialog> dialogs_;
  int64_t next_dialog_ = 0;

  // False once the page is gone: what a timer or a DevTools answer arrives for after that is dropped.
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
};

}  // namespace challenge_browser

#endif  // FLUTTER_PLUGIN_CHALLENGE_BROWSER_PAGE_H_
