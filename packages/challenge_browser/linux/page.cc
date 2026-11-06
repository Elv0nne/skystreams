#include "page.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

namespace {

// The document's own controls. Not frames: focusing a frame element reaches none of its controls.
#define FOCUSABLE "a[href],button,input,select,textarea,[tabindex]:not([tabindex=\"-1\"])"
constexpr char kFocusFirst[] = "(function(){var e=document.querySelector('" FOCUSABLE "');if(e)e.focus();})()";
constexpr char kFocusLast[] =
    "(function(){var e=document.querySelectorAll('" FOCUSABLE "');if(e.length)e[e.length-1].focus();})()";
#undef FOCUSABLE

ChallengeBrowserPageEvent* Event(ChallengeBrowserPageEventKind kind, const gchar* url = nullptr) {
  return challenge_browser_page_event_new(kind, url, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                                          nullptr, nullptr, nullptr, nullptr);
}

// A served file's type, by its extension: what a page's own scripts, styles and media need.
const char* Type(const gchar* path) {
  const char* dot = strrchr(path, '.');
  g_autofree gchar* extension = g_ascii_strdown(dot ? dot + 1 : "", -1);
  static const std::map<std::string, const char*> kTypes = {
      {"html", "text/html"},       {"htm", "text/html"},        {"js", "text/javascript"},
      {"mjs", "text/javascript"},  {"css", "text/css"},         {"json", "application/json"},
      {"wasm", "application/wasm"}, {"svg", "image/svg+xml"},   {"png", "image/png"},
      {"jpg", "image/jpeg"},       {"jpeg", "image/jpeg"},      {"gif", "image/gif"},
      {"webp", "image/webp"},      {"mp3", "audio/mpeg"},       {"ogg", "audio/ogg"},
      {"wav", "audio/wav"},        {"mp4", "video/mp4"},        {"txt", "text/plain"}};
  const auto found = kTypes.find(extension);
  return found == kTypes.end() ? "application/octet-stream" : found->second;
}

void NotServed(WebKitURISchemeRequest* request) {
  g_autoptr(GError) error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "Not served");
  webkit_uri_scheme_request_finish_error(request, error);
}

// Waits for each cookie's deletion before answering.
struct Deletion {
  ChallengeBrowserPageHostApiResponseHandle* response;
  int pending;
};

void Settle(Deletion* deletion) {
  if (--deletion->pending > 0) return;
  challenge_browser_page_host_api_respond_delete_cookies(deletion->response);
  g_object_unref(deletion->response);
  delete deletion;
}

void Deleted(GObject* manager, GAsyncResult* result, gpointer data) {
  webkit_cookie_manager_delete_cookie_finish(WEBKIT_COOKIE_MANAGER(manager), result, nullptr);
  Settle(static_cast<Deletion*>(data));
}

}  // namespace

Page::Page(WebKitWebContext* context,
           GtkOverlay* overlay,
           FlView* view,
           const gchar* channel,
           std::function<void(ChallengeBrowserPageEvent*)> emit)
    : overlay_(overlay), view_(view), content_(webkit_user_content_manager_new()), emit_(std::move(emit)) {
  web_view_ = WEBKIT_WEB_VIEW(g_object_ref_sink(
      g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", context, "user-content-manager", content_, nullptr)));
  webkit_user_content_manager_register_script_message_handler(content_, channel);
  g_autofree gchar* message = g_strdup_printf("script-message-received::%s", channel);
  g_signal_connect(content_, message, G_CALLBACK(OnScriptMessage), this);
  g_signal_connect(web_view_, "load-changed", G_CALLBACK(OnLoadChanged), this);
  g_signal_connect(web_view_, "decide-policy", G_CALLBACK(OnDecidePolicy), this);
  g_signal_connect(web_view_, "load-failed", G_CALLBACK(OnLoadFailed), this);
  g_signal_connect(web_view_, "notify::estimated-load-progress", G_CALLBACK(OnProgress), this);
  g_signal_connect(web_view_, "web-process-terminated", G_CALLBACK(OnTerminated), this);
  g_signal_connect(web_view_, "resource-load-started", G_CALLBACK(OnResourceLoadStarted), this);
  g_signal_connect(web_view_, "focus-in-event", G_CALLBACK(OnFocusIn), this);
  g_signal_connect(web_view_, "focus-out-event", G_CALLBACK(OnFocusOut), this);
  g_signal_connect(web_view_, "key-press-event", G_CALLBACK(OnKey), this);
  g_signal_connect(web_view_, "key-release-event", G_CALLBACK(OnKey), this);
  g_signal_connect(web_view_, "script-dialog", G_CALLBACK(OnScriptDialog), this);
  gtk_overlay_add_overlay(overlay_, widget());
  Hide();
  gtk_widget_show(widget());
}

Page::~Page() {
  // A held dialog keeps its page waiting: each is let go, cancelled, before the page goes.
  for (const auto& [id, dialog] : dialogs_) {
    webkit_script_dialog_close(dialog);
    webkit_script_dialog_unref(dialog);
  }
  dialogs_.clear();
  Blur();
  g_signal_handlers_disconnect_by_data(web_view_, this);
  g_signal_handlers_disconnect_by_data(content_, this);
  gtk_widget_destroy(widget());
  g_object_unref(web_view_);
  g_object_unref(content_);
}

void Page::Load(const gchar* url, FlValue* headers) {
  g_autoptr(WebKitURIRequest) request = webkit_uri_request_new(url);
  SoupMessageHeaders* fields = webkit_uri_request_get_http_headers(request);
  for (size_t i = 0; fields && i < fl_value_get_length(headers); i++) {
    soup_message_headers_append(fields, fl_value_get_string(fl_value_get_map_key(headers, i)),
                                fl_value_get_string(fl_value_get_map_value(headers, i)));
  }
  webkit_web_view_load_request(web_view_, request);
}

void Page::Evaluate(const gchar* script, ChallengeBrowserPageHostApiResponseHandle* response) {
  webkit_web_view_evaluate_javascript(
      web_view_, script, -1, nullptr, nullptr, nullptr,
      [](GObject* web_view, GAsyncResult* result, gpointer data) {
        g_autoptr(ChallengeBrowserPageHostApiResponseHandle) response = CHALLENGE_BROWSER_PAGE_HOST_API_RESPONSE_HANDLE(data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(web_view), result, &error);
        if (!value) {
          challenge_browser_page_host_api_respond_error_evaluate(response, "script", error->message, nullptr);
          return;
        }
        // JSON: undefined, and what JSON can't hold, is "null".
        g_autofree gchar* json = jsc_value_to_json(value, 0);
        challenge_browser_page_host_api_respond_evaluate(response, json ? json : "null");
      },
      g_object_ref(response));
}

void Page::EvaluateIsolated(const gchar* script, ChallengeBrowserPageHostApiResponseHandle* response) {
  webkit_web_view_evaluate_javascript(
      web_view_, script, -1, "skystream", nullptr, nullptr,
      [](GObject* web_view, GAsyncResult* result, gpointer data) {
        g_autoptr(ChallengeBrowserPageHostApiResponseHandle) response = CHALLENGE_BROWSER_PAGE_HOST_API_RESPONSE_HANDLE(data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(web_view), result, &error);
        if (!value) {
          challenge_browser_page_host_api_respond_error_evaluate_isolated(response, "script", error->message, nullptr);
          return;
        }
        g_autofree gchar* json = jsc_value_to_json(value, 0);
        challenge_browser_page_host_api_respond_evaluate_isolated(response, json ? json : "null");
      },
      g_object_ref(response));
}

namespace {

// One tap's pointer events, a frame apart, sent from GLib timeouts on the main loop. It holds the web
// view and the reply until it's done.
struct TapRun {
  WebKitWebView* view;
  ChallengeBrowserPageHostApiResponseHandle* response;
  double x;
  double y;
  int step;
};

constexpr int kMoves = 12;

void SendPointer(GtkWidget* widget, GdkEventType type, double x, double y) {
  GdkWindow* window = gtk_widget_get_window(widget);
  // Events are in their window's coordinates; a web view without a window of its own sits in its
  // parent's, at its allocation.
  if (!gtk_widget_get_has_window(widget)) {
    GtkAllocation allocation;
    gtk_widget_get_allocation(widget, &allocation);
    x += allocation.x;
    y += allocation.y;
  }
  GdkDevice* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_window_get_display(window)));
  const guint32 time = static_cast<guint32>(g_get_monotonic_time() / 1000);
  GdkEvent* event = gdk_event_new(type);
  if (type == GDK_MOTION_NOTIFY) {
    event->motion.window = GDK_WINDOW(g_object_ref(window));
    event->motion.send_event = FALSE;
    event->motion.time = time;
    event->motion.x = x;
    event->motion.y = y;
  } else {
    event->button.window = GDK_WINDOW(g_object_ref(window));
    event->button.send_event = FALSE;
    event->button.time = time;
    event->button.x = x;
    event->button.y = y;
    event->button.button = 1;
    event->button.state = type == GDK_BUTTON_RELEASE ? GDK_BUTTON1_MASK : 0;
  }
  gdk_event_set_device(event, pointer);
  gtk_widget_event(widget, event);
  gdk_event_free(event);
}

gboolean TapStep(gpointer data) {
  auto* run = static_cast<TapRun*>(data);
  GtkWidget* widget = GTK_WIDGET(run->view);
  if (!gtk_widget_get_window(widget)) {
    challenge_browser_page_host_api_respond_error_tap(run->response, "no-window", "The page has no window", nullptr);
  } else if (run->step < kMoves) {
    // A hand on a mouse: an eased move from up and to the left.
    const double t = (run->step + 1) / static_cast<double>(kMoves);
    const double eased = t * t * (3 - 2 * t);
    SendPointer(widget, GDK_MOTION_NOTIFY, run->x - 140 + 140 * eased, run->y - 70 + 70 * eased);
    run->step++;
    g_timeout_add(16, TapStep, run);
    return G_SOURCE_REMOVE;
  } else if (run->step == kMoves) {
    SendPointer(widget, GDK_BUTTON_PRESS, run->x, run->y);
    run->step++;
    // A finger's rest before the release.
    g_timeout_add(80 + g_random_int_range(0, 61), TapStep, run);
    return G_SOURCE_REMOVE;
  } else {
    SendPointer(widget, GDK_BUTTON_RELEASE, run->x, run->y);
    challenge_browser_page_host_api_respond_tap(run->response);
  }
  g_object_unref(run->view);
  g_object_unref(run->response);
  g_free(run);
  return G_SOURCE_REMOVE;
}

}  // namespace

void Page::Tap(double x, double y, ChallengeBrowserPageHostApiResponseHandle* response) {
  auto* run = g_new0(TapRun, 1);
  run->view = WEBKIT_WEB_VIEW(g_object_ref(web_view_));
  run->response = CHALLENGE_BROWSER_PAGE_HOST_API_RESPONSE_HANDLE(g_object_ref(response));
  run->x = x;
  run->y = y;
  TapStep(run);
}

void Page::AddDocumentStartScript(const gchar* script) {
  g_autoptr(WebKitUserScript) user_script = webkit_user_script_new(
      script, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, nullptr, nullptr);
  webkit_user_content_manager_add_script(content_, user_script);
}

void Page::Cookies(const gchar* url, ChallengeBrowserPageHostApiResponseHandle* response) {
  webkit_cookie_manager_get_cookies(
      CookieManager(), url, nullptr,
      [](GObject* manager, GAsyncResult* result, gpointer data) {
        g_autoptr(ChallengeBrowserPageHostApiResponseHandle) response = CHALLENGE_BROWSER_PAGE_HOST_API_RESPONSE_HANDLE(data);
        g_autoptr(GError) error = nullptr;
        GList* cookies = webkit_cookie_manager_get_cookies_finish(WEBKIT_COOKIE_MANAGER(manager), result, &error);
        if (error) {
          challenge_browser_page_host_api_respond_error_cookies(response, "cookies", error->message, nullptr);
          return;
        }
        g_autoptr(FlValue) list = fl_value_new_list();
        for (GList* item = cookies; item; item = item->next) {
          SoupCookie* cookie = static_cast<SoupCookie*>(item->data);
          GDateTime* expires = soup_cookie_get_expires(cookie);
          int64_t expires_ms = expires ? g_date_time_to_unix(expires) * 1000 : 0;
          g_autoptr(ChallengeBrowserPageCookie) out = challenge_browser_page_cookie_new(
              soup_cookie_get_name(cookie), soup_cookie_get_value(cookie), soup_cookie_get_domain(cookie),
              soup_cookie_get_path(cookie), expires ? &expires_ms : nullptr, soup_cookie_get_http_only(cookie),
              soup_cookie_get_secure(cookie));
          fl_value_append_take(list, fl_value_new_custom_object(challenge_browser_page_cookie_type_id, G_OBJECT(out)));
        }
        g_list_free_full(cookies, reinterpret_cast<GDestroyNotify>(soup_cookie_free));
        challenge_browser_page_host_api_respond_cookies(response, list);
      },
      g_object_ref(response));
}

void Page::DeleteCookies(const gchar* url, const gchar* name, ChallengeBrowserPageHostApiResponseHandle* response) {
  // The name to delete, or every cookie of [url] for null.
  struct Request {
    ChallengeBrowserPageHostApiResponseHandle* response;
    gchar* name;
  };
  webkit_cookie_manager_get_cookies(
      CookieManager(), url, nullptr,
      [](GObject* manager, GAsyncResult* result, gpointer data) {
        auto* request = static_cast<Request*>(data);
        g_autoptr(GError) error = nullptr;
        GList* cookies = webkit_cookie_manager_get_cookies_finish(WEBKIT_COOKIE_MANAGER(manager), result, &error);
        if (error) {
          challenge_browser_page_host_api_respond_error_delete_cookies(request->response, "cookies", error->message,
                                                                       nullptr);
          g_object_unref(request->response);
        } else {
          // Answered once every deletion has, and this lookup.
          auto* deletion = new Deletion{request->response, 1};
          for (GList* item = cookies; item; item = item->next) {
            SoupCookie* cookie = static_cast<SoupCookie*>(item->data);
            if (request->name && g_strcmp0(soup_cookie_get_name(cookie), request->name) != 0) continue;
            deletion->pending++;
            webkit_cookie_manager_delete_cookie(WEBKIT_COOKIE_MANAGER(manager), cookie, nullptr, Deleted, deletion);
          }
          g_list_free_full(cookies, reinterpret_cast<GDestroyNotify>(soup_cookie_free));
          Settle(deletion);
        }
        g_free(request->name);
        delete request;
      },
      new Request{CHALLENGE_BROWSER_PAGE_HOST_API_RESPONSE_HANDLE(g_object_ref(response)), g_strdup(name)});
}

const gchar* Page::UserAgent() {
  return webkit_settings_get_user_agent(webkit_web_view_get_settings(web_view_));
}

void Page::SetUserAgent(const gchar* agent) {
  webkit_settings_set_user_agent(webkit_web_view_get_settings(web_view_), agent);
}

std::string Page::ServeFolder(const gchar* name, const gchar* folder) {
  g_autofree gchar* lower = g_ascii_strdown(name, -1);
  folders_[lower] = folder;
  return std::string("cbfolder://") + lower + "/";
}

void Page::Serve(WebKitURISchemeRequest* request) {
  // cbfolder://<name>/<path>: the name's folder, and the file below it.
  const std::string uri = webkit_uri_scheme_request_get_uri(request);
  const size_t start = strlen("cbfolder://");
  const size_t end = uri.find_first_of("/?#", start);
  g_autofree gchar* name =
      g_ascii_strdown(uri.substr(start, end == std::string::npos ? std::string::npos : end - start).c_str(), -1);
  const auto folder = folders_.find(name);
  if (folder == folders_.end()) return NotServed(request);
  // An escaped "/" is refused: it could climb out of the folder.
  g_autofree gchar* path = g_uri_unescape_string(webkit_uri_scheme_request_get_path(request), "/");
  g_autofree gchar* root = realpath(folder->second.c_str(), nullptr);
  if (!path || !root) return NotServed(request);
  g_autofree gchar* joined = g_build_filename(root, path, nullptr);
  g_autofree gchar* file = realpath(joined, nullptr);
  g_autofree gchar* inside = g_strconcat(root, "/", nullptr);
  if (!file || !g_str_has_prefix(file, inside) || !g_file_test(file, G_FILE_TEST_IS_REGULAR)) return NotServed(request);
  g_autoptr(GFile) source = g_file_new_for_path(file);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GFileInfo) info =
      g_file_query_info(source, G_FILE_ATTRIBUTE_STANDARD_SIZE, G_FILE_QUERY_INFO_NONE, nullptr, &error);
  g_autoptr(GFileInputStream) stream = info ? g_file_read(source, nullptr, &error) : nullptr;
  if (!stream) {
    webkit_uri_scheme_request_finish_error(request, error);
    return;
  }
  // WebKit reads the stream itself (a game's file is up to 16 MB); status 200, as a page's XHR expects of its file.
  g_autoptr(WebKitURISchemeResponse) response =
      webkit_uri_scheme_response_new(G_INPUT_STREAM(stream), g_file_info_get_size(info));
  webkit_uri_scheme_response_set_status(response, 200, nullptr);
  webkit_uri_scheme_response_set_content_type(response, Type(file));
  webkit_uri_scheme_request_finish_with_response(request, response);
}

void Page::SetFrame(ChallengeBrowserPageFrame* frame) {
  shown_ = frame != nullptr;
  if (frame) {
    const double left = challenge_browser_page_frame_get_left(frame);
    const double top = challenge_browser_page_frame_get_top(frame);
    const int x = static_cast<int>(std::lround(left));
    const int y = static_cast<int>(std::lround(top));
    frame_ = {x, y, static_cast<int>(std::lround(left + challenge_browser_page_frame_get_width(frame))) - x,
              static_cast<int>(std::lround(top + challenge_browser_page_frame_get_height(frame))) - y};
    gtk_widget_set_opacity(widget(), 1);
    gtk_overlay_set_overlay_pass_through(overlay_, widget(), FALSE);
    gtk_widget_set_can_focus(widget(), TRUE);
  } else {
    // A page out of sight keeps no keys.
    Blur();
    Hide();
  }
  gtk_widget_queue_resize(widget());
  if (shown_ && pending_focus_) {
    const bool forward = *pending_focus_;
    pending_focus_.reset();
    Focus(forward);
  }
}

void Page::Hide() {
  // Drawn, so WebKit keeps the page running, animation frames included; but unseen, and out of
  // reach of the pointer and of Tab.
  gtk_widget_set_opacity(widget(), 0);
  gtk_overlay_set_overlay_pass_through(overlay_, widget(), TRUE);
  gtk_widget_set_can_focus(widget(), FALSE);
}

void Page::Focus(bool forward) {
  if (!shown_) {
    pending_focus_ = forward;
    return;
  }
  gtk_widget_grab_focus(widget());
  // WebKitGTK picks no control by itself: the page's document does, its first or its last.
  webkit_web_view_evaluate_javascript(web_view_, forward ? kFocusFirst : kFocusLast, -1, nullptr, nullptr, nullptr,
                                      nullptr, nullptr);
}

void Page::Blur() {
  pending_focus_.reset();
  if (gtk_widget_is_focus(widget())) gtk_widget_grab_focus(GTK_WIDGET(view_));
}

void Page::Leave(GtkDirectionType direction) {
  gtk_widget_grab_focus(GTK_WIDGET(view_));
  ChallengeBrowserFocusDirection towards = direction == GTK_DIR_TAB_BACKWARD
                                               ? CHALLENGE_BROWSER_FOCUS_DIRECTION_BACKWARD
                                               : CHALLENGE_BROWSER_FOCUS_DIRECTION_FORWARD;
  Emit(challenge_browser_page_event_new(CHALLENGE_BROWSER_PAGE_EVENT_KIND_FOCUS_EXIT, nullptr, nullptr, nullptr,
                                        nullptr, nullptr, nullptr, nullptr, nullptr, &towards, nullptr, nullptr, nullptr));
}

void Page::Emit(ChallengeBrowserPageEvent* event) {
  emit_(event);
  g_object_unref(event);
}

WebKitCookieManager* Page::CookieManager() {
  return webkit_web_context_get_cookie_manager(webkit_web_view_get_context(web_view_));
}

bool Page::Stopped(const gchar* uri) {
  if (uri == nullptr) return false;
  for (const auto& prefix : navigation_stops_) {
    if (g_str_has_prefix(uri, prefix.c_str())) {
      Emit(Event(CHALLENGE_BROWSER_PAGE_EVENT_KIND_NAVIGATION_STOPPED, uri));
      return true;
    }
  }
  return false;
}

// Asked for the main frame's navigations and each of their redirects: a sign-in's redirect is
// caught here before anything is requested from it.
gboolean Page::OnDecidePolicy(WebKitWebView*,
                              WebKitPolicyDecision* decision,
                              WebKitPolicyDecisionType type,
                              Page* self) {
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return FALSE;
  WebKitNavigationAction* action =
      webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
  if (!self->Stopped(webkit_uri_request_get_uri(webkit_navigation_action_get_request(action)))) return FALSE;
  webkit_policy_decision_ignore(decision);
  return TRUE;
}

void Page::OnLoadChanged(WebKitWebView* web_view, WebKitLoadEvent load_event, Page* self) {
  if (load_event == WEBKIT_LOAD_REDIRECTED && self->Stopped(webkit_web_view_get_uri(web_view))) {
    // A redirect the policy check didn't see.
    webkit_web_view_stop_loading(web_view);
    return;
  }
  if (load_event == WEBKIT_LOAD_STARTED) {
    self->failed_ = false;
    self->Emit(Event(CHALLENGE_BROWSER_PAGE_EVENT_KIND_PAGE_STARTED, webkit_web_view_get_uri(web_view)));
  } else if (load_event == WEBKIT_LOAD_FINISHED && !self->failed_) {
    self->Emit(Event(CHALLENGE_BROWSER_PAGE_EVENT_KIND_PAGE_FINISHED, webkit_web_view_get_uri(web_view)));
  }
}

gboolean Page::OnLoadFailed(WebKitWebView*, WebKitLoadEvent, const gchar* uri, GError* error, Page* self) {
  // A load another one replaced.
  if (g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) return FALSE;
  self->failed_ = true;
  int64_t code = error->code;
  gboolean main_frame = TRUE;
  self->Emit(challenge_browser_page_event_new(CHALLENGE_BROWSER_PAGE_EVENT_KIND_PAGE_ERROR, uri, &code,
                                              error->message, &main_frame, nullptr, nullptr, nullptr, nullptr,
                                              nullptr, nullptr, nullptr, nullptr));
  return FALSE;
}

void Page::OnProgress(WebKitWebView* web_view, GParamSpec*, Page* self) {
  double progress = webkit_web_view_get_estimated_load_progress(web_view);
  self->Emit(challenge_browser_page_event_new(CHALLENGE_BROWSER_PAGE_EVENT_KIND_PROGRESS, nullptr, nullptr, nullptr,
                                              nullptr, &progress, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                                              nullptr));
}

void Page::OnTerminated(WebKitWebView*, WebKitWebProcessTerminationReason reason, Page* self) {
  gboolean crashed = reason == WEBKIT_WEB_PROCESS_CRASHED;
  self->Emit(challenge_browser_page_event_new(CHALLENGE_BROWSER_PAGE_EVENT_KIND_RENDERER_GONE, nullptr, nullptr,
                                              nullptr, nullptr, nullptr, &crashed, nullptr, nullptr, nullptr, nullptr,
                                              nullptr, nullptr));
}

void Page::OnResourceLoadStarted(WebKitWebView*, WebKitWebResource*, WebKitURIRequest* request, Page* self) {
  if (!self->capturing_) return;
  const gchar* method = webkit_uri_request_get_http_method(request);
  self->Emit(challenge_browser_page_event_new(CHALLENGE_BROWSER_PAGE_EVENT_KIND_CAPTURED,
                                              webkit_uri_request_get_uri(request), nullptr, nullptr, nullptr,
                                              nullptr, nullptr, nullptr, method ? method : "GET", nullptr, nullptr,
                                              nullptr, nullptr));
}

void Page::OnScriptMessage(WebKitUserContentManager*, WebKitJavascriptResult* result, Page* self) {
  JSCValue* value = webkit_javascript_result_get_js_value(result);
  // A string as it was posted; anything else as JSON.
  g_autofree gchar* text = jsc_value_is_string(value) ? jsc_value_to_string(value) : jsc_value_to_json(value, 0);
  self->Emit(challenge_browser_page_event_new(CHALLENGE_BROWSER_PAGE_EVENT_KIND_SCRIPT_MESSAGE, nullptr, nullptr,
                                              nullptr, nullptr, nullptr, nullptr, text ? text : "null", nullptr,
                                              nullptr, nullptr, nullptr, nullptr));
}

gboolean Page::OnFocusIn(GtkWidget*, GdkEventFocus*, Page* self) {
  // From a click too, which Flutter doesn't hear of.
  self->Emit(Event(CHALLENGE_BROWSER_PAGE_EVENT_KIND_FOCUSED));
  return FALSE;
}

gboolean Page::OnFocusOut(GtkWidget*, GdkEventFocus*, Page* self) {
  self->Emit(Event(CHALLENGE_BROWSER_PAGE_EVENT_KIND_BLURRED));
  return FALSE;
}

gboolean Page::OnKey(GtkWidget*, GdkEventKey* event, Page* self) {
  if (event->keyval != GDK_KEY_Escape) return FALSE;
  // Escape belongs to Flutter, to close what shows the page: it gets the key as if pressed there.
  return gtk_widget_event(GTK_WIDGET(self->view_), reinterpret_cast<GdkEvent*>(event));
}

gboolean Page::OnScriptDialog(WebKitWebView* web_view, WebKitScriptDialog* dialog, Page* self) {
  // Not held: WebKitGTK's own dialog.
  if (!self->holds_dialogs_) return FALSE;
  const WebKitScriptDialogType type = webkit_script_dialog_get_dialog_type(dialog);
  // A page leaving asks no one.
  if (type == WEBKIT_SCRIPT_DIALOG_BEFORE_UNLOAD_CONFIRM) {
    webkit_script_dialog_confirm_set_confirmed(dialog, TRUE);
    return TRUE;
  }
  ChallengeBrowserDialogKind kind = type == WEBKIT_SCRIPT_DIALOG_ALERT     ? CHALLENGE_BROWSER_DIALOG_KIND_ALERT
                                    : type == WEBKIT_SCRIPT_DIALOG_CONFIRM ? CHALLENGE_BROWSER_DIALOG_KIND_CONFIRM
                                                                           : CHALLENGE_BROWSER_DIALOG_KIND_PROMPT;
  int64_t id = ++self->next_dialog_;
  // Answered later, from the main loop: WebKitGTK keeps the page waiting while it's held.
  self->dialogs_[id] = webkit_script_dialog_ref(dialog);
  const gchar* default_text =
      type == WEBKIT_SCRIPT_DIALOG_PROMPT ? webkit_script_dialog_prompt_get_default_text(dialog) : nullptr;
  self->Emit(challenge_browser_page_event_new(CHALLENGE_BROWSER_PAGE_EVENT_KIND_DIALOG,
                                              webkit_web_view_get_uri(web_view), nullptr, nullptr, nullptr, nullptr,
                                              nullptr, webkit_script_dialog_get_message(dialog), nullptr, nullptr, &id,
                                              &kind, default_text));
  return TRUE;
}

void Page::AnswerDialog(int64_t id, bool accept, const gchar* text) {
  const auto found = dialogs_.find(id);
  if (found == dialogs_.end()) return;
  WebKitScriptDialog* dialog = found->second;
  dialogs_.erase(found);
  switch (webkit_script_dialog_get_dialog_type(dialog)) {
    case WEBKIT_SCRIPT_DIALOG_CONFIRM:
      webkit_script_dialog_confirm_set_confirmed(dialog, accept);
      break;
    case WEBKIT_SCRIPT_DIALOG_PROMPT:
      // Left unset, a prompt answers null.
      if (accept) webkit_script_dialog_prompt_set_text(dialog, text ? text : "");
      break;
    default:
      break;
  }
  webkit_script_dialog_close(dialog);
  webkit_script_dialog_unref(dialog);
}
