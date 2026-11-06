#include "page.h"

#include <flutter_windows.h>

#include <cmath>
#include <cstdio>
#include <map>

namespace challenge_browser {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

// Runs a function after a delay, on this thread's message loop (the UI thread's), without blocking it.
std::map<UINT_PTR, std::function<void()>>& Timers() {
  static std::map<UINT_PTR, std::function<void()>> timers;
  return timers;
}

void CALLBACK OnTimer(HWND, UINT, UINT_PTR id, DWORD) {
  KillTimer(nullptr, id);
  auto found = Timers().find(id);
  if (found == Timers().end()) return;
  std::function<void()> run = std::move(found->second);
  Timers().erase(found);
  run();
}

void After(UINT milliseconds, std::function<void()> run) {
  const UINT_PTR id = SetTimer(nullptr, 0, milliseconds, OnTimer);
  if (id == 0) return run();
  Timers()[id] = std::move(run);
}

// A whole CSS pixel, as JSON: no decimal separator for a locale to change.
std::string Number(double value) { return std::to_string(std::lround(value)); }

// Where a hidden page waits: outside Flutter's view, at a usual size, so pages lay out and run as
// they would shown.
constexpr RECT kHidden = {-20000, -20000, -20000 + 1024, -20000 + 768};

// A string WebView2 handed out, which the caller frees.
std::string Take(LPWSTR text) {
  std::string out = Utf8(text);
  CoTaskMemFree(text);
  return out;
}

const char* ErrorText(COREWEBVIEW2_WEB_ERROR_STATUS status) {
  switch (status) {
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT:
      return "certificate common name is incorrect";
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED:
      return "certificate expired";
    case COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS:
      return "client certificate contains errors";
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED:
      return "certificate revoked";
    case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID:
      return "certificate is invalid";
    case COREWEBVIEW2_WEB_ERROR_STATUS_SERVER_UNREACHABLE:
      return "server unreachable";
    case COREWEBVIEW2_WEB_ERROR_STATUS_TIMEOUT:
      return "timeout";
    case COREWEBVIEW2_WEB_ERROR_STATUS_ERROR_HTTP_INVALID_SERVER_RESPONSE:
      return "invalid server response";
    case COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_ABORTED:
      return "connection aborted";
    case COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_RESET:
      return "connection reset";
    case COREWEBVIEW2_WEB_ERROR_STATUS_DISCONNECTED:
      return "disconnected";
    case COREWEBVIEW2_WEB_ERROR_STATUS_CANNOT_CONNECT:
      return "cannot connect";
    case COREWEBVIEW2_WEB_ERROR_STATUS_HOST_NAME_NOT_RESOLVED:
      return "host name not resolved";
    case COREWEBVIEW2_WEB_ERROR_STATUS_REDIRECT_FAILED:
      return "redirect failed";
    case COREWEBVIEW2_WEB_ERROR_STATUS_VALID_AUTHENTICATION_CREDENTIALS_REQUIRED:
      return "authentication required";
    case COREWEBVIEW2_WEB_ERROR_STATUS_VALID_PROXY_AUTHENTICATION_REQUIRED:
      return "proxy authentication required";
    default:
      return "unexpected error";
  }
}

PageCookie ToPageCookie(ICoreWebView2Cookie* cookie) {
  LPWSTR name = nullptr, value = nullptr, domain = nullptr, path = nullptr;
  double expires = -1;
  BOOL http_only = FALSE, secure = FALSE, session = TRUE;
  cookie->get_Name(&name);
  cookie->get_Value(&value);
  cookie->get_Domain(&domain);
  cookie->get_Path(&path);
  cookie->get_Expires(&expires);
  cookie->get_IsHttpOnly(&http_only);
  cookie->get_IsSecure(&secure);
  cookie->get_IsSession(&session);
  // WebView2 counts seconds since the epoch.
  const int64_t expires_ms = static_cast<int64_t>(expires * 1000);
  return PageCookie(Take(name), Take(value), Take(domain), Take(path), session ? nullptr : &expires_ms,
                    http_only == TRUE, secure == TRUE);
}

}  // namespace

std::wstring Utf16(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), size);
  return out;
}

std::string Utf8(const wchar_t* text) {
  if (!text || !*text) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  std::string out(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
  return out;
}

FlutterError Failure(const std::string& code, HRESULT result) {
  char text[32];
  std::snprintf(text, sizeof(text), "HRESULT 0x%08lX", static_cast<unsigned long>(result));
  return FlutterError(code, text);
}

Page::Page(ComPtr<ICoreWebView2Environment> environment,
           ComPtr<ICoreWebView2Controller> controller,
           HWND flutter_view,
           std::function<void(const PageEvent&)> emit)
    : environment_(std::move(environment)),
      controller_(std::move(controller)),
      flutter_view_(flutter_view),
      emit_(std::move(emit)) {
  controller_->get_CoreWebView2(&webview_);
  controller_->put_Bounds(kHidden);
  FollowMonitorScale(false);
  controller_->put_IsVisible(TRUE);
  // SmartScreen's "Reported Unsafe Site" stops checks on sites the app reaches
  // over HTTP anyway.
  ComPtr<ICoreWebView2Settings> settings;
  ComPtr<ICoreWebView2Settings8> settings8;
  if (SUCCEEDED(webview_->get_Settings(&settings)) && SUCCEEDED(settings.As(&settings8))) {
    settings8->put_IsReputationCheckingRequired(FALSE);
  }

  EventRegistrationToken token;
  webview_->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [this](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            LPWSTR uri = nullptr;
            args->get_Uri(&uri);
            const std::string url = Take(uri);
            // Raised for the main frame's navigations and each of their redirects: a sign-in's
            // redirect is caught here before anything is requested from it.
            for (const auto& prefix : navigation_stops_) {
              if (url.rfind(prefix, 0) == 0) {
                args->put_Cancel(TRUE);
                PageEvent stopped(PageEventKind::kNavigationStopped);
                stopped.set_url(url);
                emit_(stopped);
                return S_OK;
              }
            }
            PageEvent started(PageEventKind::kPageStarted);
            started.set_url(url);
            emit_(started);
            // WebView2 reports no progress in between.
            PageEvent progress(PageEventKind::kProgress);
            progress.set_progress(0.1);
            emit_(progress);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_NavigationCompleted(
      Callback<ICoreWebView2NavigationCompletedEventHandler>(
          [this](ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
            BOOL success = FALSE;
            args->get_IsSuccess(&success);
            LPWSTR source = nullptr;
            sender->get_Source(&source);
            const std::string url = Take(source);
            // WebView2 counts a page the server answered with an error status as failed: Cloudflare's
            // check comes as a 403. The other engines count it as loaded, and so does this.
            int status_code = 0;
            ComPtr<ICoreWebView2NavigationCompletedEventArgs2> answered;
            if (!success && SUCCEEDED(args->QueryInterface(IID_PPV_ARGS(&answered)))) {
              answered->get_HttpStatusCode(&status_code);
            }
            if (success || status_code > 0) {
              PageEvent progress(PageEventKind::kProgress);
              progress.set_progress(1.0);
              emit_(progress);
              PageEvent finished(PageEventKind::kPageFinished);
              finished.set_url(url);
              emit_(finished);
              return S_OK;
            }
            COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
            args->get_WebErrorStatus(&status);
            // A load another one replaced.
            if (status == COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED) return S_OK;
            PageEvent error(PageEventKind::kPageError);
            error.set_url(url);
            error.set_code(static_cast<int64_t>(status));
            error.set_error_text(ErrorText(status));
            error.set_main_frame(true);
            emit_(error);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
          [this](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
            LPWSTR text = nullptr;
            // A string as it was posted; anything else as JSON.
            if (FAILED(args->TryGetWebMessageAsString(&text))) args->get_WebMessageAsJson(&text);
            PageEvent message(PageEventKind::kScriptMessage);
            message.set_message(Take(text));
            emit_(message);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_WebResourceRequested(
      Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [this](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
            // Only while capturing: the filter decides what arrives. Nothing is answered or changed.
            ComPtr<ICoreWebView2WebResourceRequest> request;
            if (FAILED(args->get_Request(&request))) return S_OK;
            LPWSTR uri = nullptr, method = nullptr;
            request->get_Uri(&uri);
            request->get_Method(&method);
            PageEvent captured(PageEventKind::kCaptured);
            captured.set_url(Take(uri));
            captured.set_method(Take(method));
            emit_(captured);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_ProcessFailed(
      Callback<ICoreWebView2ProcessFailedEventHandler>(
          [this](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
            COREWEBVIEW2_PROCESS_FAILED_KIND kind;
            args->get_ProcessFailedKind(&kind);
            if (kind != COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED &&
                kind != COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED) {
              return S_OK;
            }
            COREWEBVIEW2_PROCESS_FAILED_REASON reason = COREWEBVIEW2_PROCESS_FAILED_REASON_UNEXPECTED;
            ComPtr<ICoreWebView2ProcessFailedEventArgs2> details;
            if (SUCCEEDED(args->QueryInterface(IID_PPV_ARGS(&details)))) details->get_Reason(&reason);
            PageEvent gone(PageEventKind::kRendererGone);
            // Ended to reclaim memory, or by someone else, rather than crashed.
            gone.set_crashed(reason != COREWEBVIEW2_PROCESS_FAILED_REASON_OUT_OF_MEMORY &&
                             reason != COREWEBVIEW2_PROCESS_FAILED_REASON_TERMINATED);
            emit_(gone);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_NewWindowRequested(
      Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
            // A short-lived page opens no windows of its own.
            args->put_Handled(TRUE);
            return S_OK;
          })
          .Get(),
      &token);
  webview_->add_ScriptDialogOpening(
      Callback<ICoreWebView2ScriptDialogOpeningEventHandler>(
          [this](ICoreWebView2*, ICoreWebView2ScriptDialogOpeningEventArgs* args) -> HRESULT {
            // Raised only while the page's dialogs are held: WebView2's own are off then.
            COREWEBVIEW2_SCRIPT_DIALOG_KIND kind = COREWEBVIEW2_SCRIPT_DIALOG_KIND_ALERT;
            args->get_Kind(&kind);
            // A page leaving asks no one.
            if (kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_BEFOREUNLOAD) return args->Accept();
            HeldDialog held{args, nullptr};
            if (FAILED(args->GetDeferral(&held.deferral))) return S_OK;
            const int64_t id = ++next_dialog_;
            dialogs_[id] = held;
            LPWSTR uri = nullptr, message = nullptr, default_text = nullptr;
            args->get_Uri(&uri);
            args->get_Message(&message);
            args->get_DefaultText(&default_text);
            const std::string text = Take(default_text);
            PageEvent dialog(PageEventKind::kDialog);
            dialog.set_url(Take(uri));
            dialog.set_message(Take(message));
            dialog.set_dialog_id(id);
            dialog.set_dialog_kind(kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_ALERT     ? DialogKind::kAlert
                                   : kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_CONFIRM ? DialogKind::kConfirm
                                                                                     : DialogKind::kPrompt);
            if (kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_PROMPT) dialog.set_default_text(text);
            emit_(dialog);
            return S_OK;
          })
          .Get(),
      &token);

  controller_->add_MoveFocusRequested(
      Callback<ICoreWebView2MoveFocusRequestedEventHandler>(
          [this](ICoreWebView2Controller*, ICoreWebView2MoveFocusRequestedEventArgs* args) -> HRESULT {
            // Tab past the page's last control, or Shift+Tab past its first.
            COREWEBVIEW2_MOVE_FOCUS_REASON reason;
            args->get_Reason(&reason);
            if (reason == COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC) return S_OK;
            args->put_Handled(TRUE);
            ReturnKeys();
            PageEvent exit(PageEventKind::kFocusExit);
            exit.set_direction(reason == COREWEBVIEW2_MOVE_FOCUS_REASON_NEXT ? FocusDirection::kForward
                                                                             : FocusDirection::kBackward);
            emit_(exit);
            return S_OK;
          })
          .Get(),
      &token);
  controller_->add_GotFocus(Callback<ICoreWebView2FocusChangedEventHandler>(
                                [this](ICoreWebView2Controller*, IUnknown*) -> HRESULT {
                                  focused_ = true;
                                  // From a click too, which Flutter doesn't see.
                                  emit_(PageEvent(PageEventKind::kFocused));
                                  return S_OK;
                                })
                                .Get(),
                            &token);
  controller_->add_LostFocus(Callback<ICoreWebView2FocusChangedEventHandler>(
                                 [this](ICoreWebView2Controller*, IUnknown*) -> HRESULT {
                                   focused_ = false;
                                   emit_(PageEvent(PageEventKind::kBlurred));
                                   return S_OK;
                                 })
                                 .Get(),
                             &token);
  controller_->add_AcceleratorKeyPressed(
      Callback<ICoreWebView2AcceleratorKeyPressedEventHandler>(
          [this](ICoreWebView2Controller*, ICoreWebView2AcceleratorKeyPressedEventArgs* args) -> HRESULT {
            UINT key = 0;
            args->get_VirtualKey(&key);
            if (key != VK_ESCAPE) return S_OK;
            // Escape belongs to Flutter, to close what shows the page: it gets the key as if pressed
            // there.
            COREWEBVIEW2_KEY_EVENT_KIND kind;
            args->get_KeyEventKind(&kind);
            INT lparam = 0;
            args->get_KeyEventLParam(&lparam);
            args->put_Handled(TRUE);
            PostMessage(flutter_view_, kind == COREWEBVIEW2_KEY_EVENT_KIND_KEY_UP ? WM_KEYUP : WM_KEYDOWN,
                        VK_ESCAPE, lparam);
            return S_OK;
          })
          .Get(),
      &token);
}

Page::~Page() {
  *alive_ = false;
  if (focused_) ReturnKeys();
  // A held dialog keeps its page waiting: each is let go, cancelled, before the page goes.
  for (const auto& [id, held] : dialogs_) held.deferral->Complete();
  dialogs_.clear();
  // Raises no more events.
  controller_->Close();
}

void Page::DevTools(const std::string& method,
                    const std::string& params_json,
                    std::function<void(ErrorOr<std::string>)> result) {
  const HRESULT started = webview_->CallDevToolsProtocolMethod(
      Utf16(method).c_str(), Utf16(params_json).c_str(),
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [result](HRESULT error, LPCWSTR json) -> HRESULT {
            if (FAILED(error)) {
              result(Failure("devtools", error));
            } else {
              result(Utf8(json));
            }
            return S_OK;
          })
          .Get());
  if (FAILED(started)) result(Failure("devtools", started));
}

namespace {

// One tap's DevTools events, sent one after another: each answer schedules the next. The callbacks
// own it; nothing owns them back.
struct TapSteps : std::enable_shared_from_this<TapSteps> {
  Page* page;
  std::weak_ptr<bool> alive;
  std::vector<std::string> events;
  std::function<void(std::optional<FlutterError>)> done;
  size_t sent = 0;

  void Next() {
    const std::shared_ptr<bool> living = alive.lock();
    if (!living || !*living) return done(FlutterError("no-page", "The page closed while tapping"));
    if (sent == events.size()) return done(std::nullopt);
    auto self = shared_from_this();
    page->DevTools("Input.dispatchMouseEvent", events[sent++], [self](ErrorOr<std::string> answer) {
      if (answer.has_error()) return self->done(answer.error());
      // A frame between moves, as real input arrives, and a finger's rest between press and release.
      const size_t left = self->events.size() - self->sent;
      After(left == 0 ? 0 : left == 1 ? 90 : 16, [self] { self->Next(); });
    });
  }
};

}  // namespace

void Page::Tap(double x, double y, std::function<void(std::optional<FlutterError>)> done) {
  auto steps = std::make_shared<TapSteps>();
  steps->page = this;
  steps->alive = alive_;
  steps->done = std::move(done);
  // A hand on a mouse: a short eased move from up and to the left, then the click.
  for (int step = 1; step <= 12; step++) {
    const double t = step / 12.0;
    const double eased = t * t * (3 - 2 * t);
    steps->events.push_back("{\"type\":\"mouseMoved\",\"x\":" + Number(x - 140 + 140 * eased) + ",\"y\":" +
                            Number(y - 70 + 70 * eased) + "}");
  }
  const std::string at = "\"x\":" + Number(x) + ",\"y\":" + Number(y);
  steps->events.push_back("{\"type\":\"mousePressed\"," + at + ",\"button\":\"left\",\"buttons\":1,\"clickCount\":1}");
  steps->events.push_back("{\"type\":\"mouseReleased\"," + at + ",\"button\":\"left\",\"buttons\":0,\"clickCount\":1}");
  steps->Next();
}

std::optional<FlutterError> Page::Load(const std::string& url, const flutter::EncodableMap& headers) {
  const std::wstring uri = Utf16(url);
  HRESULT result = S_OK;
  if (headers.empty()) {
    result = webview_->Navigate(uri.c_str());
  } else {
    std::wstring lines;
    for (const auto& [name, value] : headers) {
      lines += Utf16(std::get<std::string>(name)) + L": " + Utf16(std::get<std::string>(value)) + L"\r\n";
    }
    ComPtr<ICoreWebView2Environment2> environment;
    ComPtr<ICoreWebView2_2> webview;
    ComPtr<ICoreWebView2WebResourceRequest> request;
    result = environment_.As(&environment);
    if (SUCCEEDED(result)) result = webview_.As(&webview);
    if (SUCCEEDED(result)) {
      result = environment->CreateWebResourceRequest(uri.c_str(), L"GET", nullptr, lines.c_str(), &request);
    }
    if (SUCCEEDED(result)) result = webview->NavigateWithWebResourceRequest(request.Get());
  }
  if (FAILED(result)) return Failure(result == E_INVALIDARG ? "bad-url" : "load", result);
  return std::nullopt;
}

void Page::Evaluate(const std::string& script, std::function<void(ErrorOr<std::string>)> result) {
  // WebView2 answers in JSON already: "null" for undefined.
  const HRESULT started = webview_->ExecuteScript(
      Utf16(script).c_str(), Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
                                 [result](HRESULT error, LPCWSTR json) -> HRESULT {
                                   if (FAILED(error)) {
                                     result(Failure("script", error));
                                   } else {
                                     result(Utf8(json));
                                   }
                                   return S_OK;
                                 })
                                 .Get());
  if (FAILED(started)) result(Failure("script", started));
}

void Page::AddDocumentStartScript(const std::string& script) {
  webview_->AddScriptToExecuteOnDocumentCreated(Utf16(script).c_str(), nullptr);
}

void Page::Cookies(const std::string& url, std::function<void(ErrorOr<flutter::EncodableList>)> result) {
  const ComPtr<ICoreWebView2CookieManager> cookies = CookieManager();
  if (!cookies) return result(FlutterError("cookies", "This WebView2 runtime has no cookie manager"));
  const HRESULT started = cookies->GetCookies(
      Utf16(url).c_str(), Callback<ICoreWebView2GetCookiesCompletedHandler>(
                              [result](HRESULT error, ICoreWebView2CookieList* list) -> HRESULT {
                                if (FAILED(error)) {
                                  result(Failure("cookies", error));
                                  return S_OK;
                                }
                                flutter::EncodableList out;
                                UINT count = 0;
                                list->get_Count(&count);
                                for (UINT i = 0; i < count; i++) {
                                  ComPtr<ICoreWebView2Cookie> cookie;
                                  if (SUCCEEDED(list->GetValueAtIndex(i, &cookie))) {
                                    out.push_back(flutter::CustomEncodableValue(ToPageCookie(cookie.Get())));
                                  }
                                }
                                result(out);
                                return S_OK;
                              })
                              .Get());
  if (FAILED(started)) result(Failure("cookies", started));
}

void Page::DeleteCookies(const std::string& url,
                         const std::string* name,
                         std::function<void(std::optional<FlutterError>)> result) {
  const ComPtr<ICoreWebView2CookieManager> cookies = CookieManager();
  if (!cookies) return result(FlutterError("cookies", "This WebView2 runtime has no cookie manager"));
  const std::optional<std::string> only = name ? std::optional<std::string>(*name) : std::nullopt;
  const HRESULT started = cookies->GetCookies(
      Utf16(url).c_str(), Callback<ICoreWebView2GetCookiesCompletedHandler>(
                              [cookies, only, result](HRESULT error, ICoreWebView2CookieList* list) -> HRESULT {
                                if (FAILED(error)) {
                                  result(Failure("cookies", error));
                                  return S_OK;
                                }
                                UINT count = 0;
                                list->get_Count(&count);
                                for (UINT i = 0; i < count; i++) {
                                  ComPtr<ICoreWebView2Cookie> cookie;
                                  if (FAILED(list->GetValueAtIndex(i, &cookie))) continue;
                                  LPWSTR raw_name = nullptr;
                                  cookie->get_Name(&raw_name);
                                  const std::string cookie_name = Take(raw_name);
                                  if (!only || cookie_name == *only) cookies->DeleteCookie(cookie.Get());
                                }
                                result(std::nullopt);
                                return S_OK;
                              })
                              .Get());
  if (FAILED(started)) result(Failure("cookies", started));
}

ErrorOr<std::string> Page::UserAgent() {
  ComPtr<ICoreWebView2Settings> settings;
  ComPtr<ICoreWebView2Settings2> settings2;
  LPWSTR agent = nullptr;
  HRESULT result = webview_->get_Settings(&settings);
  if (SUCCEEDED(result)) result = settings.As(&settings2);
  if (SUCCEEDED(result)) result = settings2->get_UserAgent(&agent);
  if (FAILED(result)) return Failure("agent", result);
  return Take(agent);
}

ErrorOr<std::optional<std::string>> Page::Title() {
  LPWSTR title = nullptr;
  const HRESULT result = webview_->get_DocumentTitle(&title);
  if (FAILED(result)) return Failure("title", result);
  if (!title) return std::optional<std::string>();
  return std::optional<std::string>(Take(title));
}

std::optional<FlutterError> Page::SetUserAgent(const std::string& agent) {
  ComPtr<ICoreWebView2Settings> settings;
  ComPtr<ICoreWebView2Settings2> settings2;
  HRESULT result = webview_->get_Settings(&settings);
  if (SUCCEEDED(result)) result = settings.As(&settings2);
  if (SUCCEEDED(result)) result = settings2->put_UserAgent(Utf16(agent).c_str());
  if (FAILED(result)) return Failure("agent", result);
  return std::nullopt;
}

ErrorOr<std::string> Page::ServeFolder(const std::string& name, const std::string& folder) {
  ComPtr<ICoreWebView2_3> served;
  HRESULT result = webview_.As(&served);
  const std::string host = name + ".example";
  // Its own pages read it; other origins' scripts may not (Microsoft's own sample maps folders so).
  if (SUCCEEDED(result)) {
    result = served->SetVirtualHostNameToFolderMapping(Utf16(host).c_str(), Utf16(folder).c_str(),
                                                       COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
  }
  if (FAILED(result)) return Failure("serve", result);
  return "https://" + host + "/";
}

void Page::HoldDialogs(bool hold) {
  // WebView2 reads it as each document loads: callers set it before loading.
  ComPtr<ICoreWebView2Settings> settings;
  if (SUCCEEDED(webview_->get_Settings(&settings))) settings->put_AreDefaultScriptDialogsEnabled(hold ? FALSE : TRUE);
}

void Page::AnswerDialog(int64_t id, bool accept, const std::string* text) {
  const auto found = dialogs_.find(id);
  if (found == dialogs_.end()) return;
  const HeldDialog held = found->second;
  dialogs_.erase(found);
  COREWEBVIEW2_SCRIPT_DIALOG_KIND kind = COREWEBVIEW2_SCRIPT_DIALOG_KIND_ALERT;
  held.args->get_Kind(&kind);
  if (accept && kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_PROMPT) {
    held.args->put_ResultText(Utf16(text ? *text : std::string()).c_str());
  }
  // Not accepted: a confirm answers false, a prompt null.
  if (accept) held.args->Accept();
  held.deferral->Complete();
}

void Page::SetCapture(bool enabled) {
  if (enabled == capturing_) return;
  capturing_ = enabled;
  ComPtr<ICoreWebView2_22> webview;
  if (SUCCEEDED(webview_.As(&webview))) {
    // Frames' and workers' requests too.
    if (enabled) {
      webview->AddWebResourceRequestedFilterWithRequestSourceKinds(
          L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL, COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL);
    } else {
      webview->RemoveWebResourceRequestedFilterWithRequestSourceKinds(
          L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL, COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL);
    }
  } else if (enabled) {
    webview_->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  } else {
    webview_->RemoveWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  }
}

void Page::SetFrame(const PageFrame* frame) {
  if (!frame) {
    // A page out of sight keeps no keys.
    if (focused_) ReturnKeys();
    shown_ = false;
    controller_->put_Bounds(kHidden);
    FollowMonitorScale(false);
    return;
  }
  FollowMonitorScale(true);
  const double scale = FlutterDesktopGetDpiForHWND(flutter_view_) / 96.0;
  const RECT bounds = {std::lround(frame->left() * scale), std::lround(frame->top() * scale),
                       std::lround((frame->left() + frame->width()) * scale),
                       std::lround((frame->top() + frame->height()) * scale)};
  controller_->put_Bounds(bounds);
  shown_ = true;
  if (pending_focus_) {
    const bool forward = *pending_focus_;
    pending_focus_.reset();
    Focus(forward);
  }
}

void Page::FollowMonitorScale(bool follow) {
  ComPtr<ICoreWebView2Controller3> scaled;
  if (FAILED(controller_.As(&scaled))) return;
  scaled->put_ShouldDetectMonitorScaleChanges(follow ? TRUE : FALSE);
  scaled->put_RasterizationScale(follow ? FlutterDesktopGetDpiForHWND(flutter_view_) / 96.0 : 1.0);
}

void Page::Focus(bool forward) {
  if (!shown_) {
    pending_focus_ = forward;
    return;
  }
  // WebView2 focuses the page's first control (its last going back), in frames too.
  controller_->MoveFocus(forward ? COREWEBVIEW2_MOVE_FOCUS_REASON_NEXT : COREWEBVIEW2_MOVE_FOCUS_REASON_PREVIOUS);
}

void Page::Blur() {
  pending_focus_.reset();
  if (focused_) ReturnKeys();
}

void Page::ParentMoved() {
  controller_->NotifyParentWindowPositionChanged();
}

void Page::ReturnKeys() {
  SetFocus(flutter_view_);
}

ComPtr<ICoreWebView2CookieManager> Page::CookieManager() {
  ComPtr<ICoreWebView2_2> webview;
  ComPtr<ICoreWebView2CookieManager> cookies;
  if (SUCCEEDED(webview_.As(&webview))) webview->get_CookieManager(&cookies);
  return cookies;
}

}  // namespace challenge_browser
