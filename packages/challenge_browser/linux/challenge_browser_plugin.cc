#include "include/challenge_browser/challenge_browser_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <map>
#include <memory>

#include "messages.g.h"
#include "page.h"

namespace {

// Runs each `ChallengeBrowser` page in a WebKitWebView of its own, laid over Flutter's view. Pages
// share one web context, so one network process and one cookie store.
struct Plugin {
  FlView* view;
  ChallengeBrowserPageFlutterApi* events;
  WebKitWebContext* context = nullptr;
  GtkOverlay* overlay = nullptr;
  GtkGesture* press = nullptr;
  std::map<int64_t, std::unique_ptr<Page>> pages;
  int64_t next_id = 0;

  ~Plugin() {
    pages.clear();
    if (overlay) g_signal_handlers_disconnect_by_data(overlay, this);
    g_clear_object(&press);
    g_clear_object(&context);
    g_clear_object(&events);
  }
};

Page* Find(Plugin* plugin, int64_t page_id) {
  const auto found = plugin->pages.find(page_id);
  return found == plugin->pages.end() ? nullptr : found->second.get();
}

gchar* NoPage(int64_t page_id) {
  return g_strdup_printf("No page %" G_GINT64_FORMAT, page_id);
}

// The overlay places pages: a shown one over its widget's rectangle, a hidden one out of sight.
gboolean OnChildPosition(GtkOverlay*, GtkWidget* widget, GdkRectangle* allocation, Plugin* plugin) {
  for (const auto& [id, page] : plugin->pages) {
    if (page->widget() != widget) continue;
    *allocation = page->Allocation();
    return TRUE;
  }
  return FALSE;
}

// GTK asks the overlay to move keyboard focus on.
gboolean OnFocus(GtkWidget* overlay, GtkDirectionType direction, Plugin* plugin) {
  GtkWidget* focused = gtk_container_get_focus_child(GTK_CONTAINER(overlay));
  for (const auto& [id, page] : plugin->pages) {
    if (page->widget() != focused) continue;
    // WebKit hands focus to the window when Tab passes the page's last control, or Shift+Tab its
    // first.
    if (direction == GTK_DIR_TAB_FORWARD || direction == GTK_DIR_TAB_BACKWARD) page->Leave(direction);
    return TRUE;
  }
  // Flutter moves its own focus: GTK's focus chain mustn't carry it into a page.
  return focused == GTK_WIDGET(plugin->view);
}

// A press anywhere over the overlay, before anything else sees it. A press on Flutter's content
// takes the keys back from a page, as a click beside a platform view does elsewhere: Flutter's view
// doesn't take focus when clicked.
void OnPress(GtkGestureMultiPress*, gint, gdouble x, gdouble y, Plugin* plugin) {
  for (const auto& [id, page] : plugin->pages) {
    if (!gtk_widget_is_focus(page->widget())) continue;
    const GdkRectangle at = page->Allocation();
    if (x >= at.x && x < at.x + at.width && y >= at.y && y < at.y + at.height) return;
    page->Blur();
  }
}

// The GtkOverlay the app's runner puts around Flutter's view, or null without one.
GtkOverlay* Overlay(Plugin* plugin) {
  if (plugin->overlay || !plugin->view) return plugin->overlay;
  GtkWidget* parent = gtk_widget_get_parent(GTK_WIDGET(plugin->view));
  if (!GTK_IS_OVERLAY(parent)) return nullptr;
  plugin->overlay = GTK_OVERLAY(parent);
  g_signal_connect(parent, "get-child-position", G_CALLBACK(OnChildPosition), plugin);
  g_signal_connect(parent, "focus", G_CALLBACK(OnFocus), plugin);
  plugin->press = gtk_gesture_multi_press_new(parent);
  gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(plugin->press), GTK_PHASE_CAPTURE);
  g_signal_connect(plugin->press, "pressed", G_CALLBACK(OnPress), plugin);
  return plugin->overlay;
}

// A request for a served folder's file: the page that asked serves it from its own folders, or nothing does.
void ServeRequest(WebKitURISchemeRequest* request, gpointer data) {
  auto* plugin = static_cast<Plugin*>(data);
  GtkWidget* asking = GTK_WIDGET(webkit_uri_scheme_request_get_web_view(request));
  for (const auto& [id, page] : plugin->pages) {
    if (page->widget() == asking) return page->Serve(request);
  }
  g_autoptr(GError) error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "Not served");
  webkit_uri_scheme_request_finish_error(request, error);
}

// The browser's own data, cookies included: in the user's data and cache folders, named for the app.
WebKitWebContext* Context(Plugin* plugin) {
  if (plugin->context) return plugin->context;
  g_autofree gchar* data = g_build_filename(g_get_user_data_dir(), g_get_prgname(), "WebKit", nullptr);
  g_autofree gchar* cache = g_build_filename(g_get_user_cache_dir(), g_get_prgname(), "WebKit", nullptr);
  g_autoptr(WebKitWebsiteDataManager) manager =
      webkit_website_data_manager_new("base-data-directory", data, "base-cache-directory", cache, nullptr);
  plugin->context = webkit_web_context_new_with_website_data_manager(manager);
  // English everywhere: the language sites read (Accept-Language and navigator.language). Cloudflare's
  // checks then read and lay out the same on every device.
  const gchar* const languages[] = {"en-US", nullptr};
  webkit_web_context_set_preferred_languages(plugin->context, languages);
  WebKitCookieManager* cookies = webkit_web_context_get_cookie_manager(plugin->context);
  g_autofree gchar* store = g_build_filename(data, "cookies.sqlite", nullptr);
  webkit_cookie_manager_set_persistent_storage(cookies, store, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
  // As on Android: a check's frame from another site keeps its cookies too.
  webkit_cookie_manager_set_accept_policy(cookies, WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS);
  // Pages' served folders (Phase 7c's §6): cbfolder://<name>/, each page reaching only its own names. Secure, so
  // storage works there, and open to their own pages' requests.
  webkit_web_context_register_uri_scheme(plugin->context, "cbfolder", ServeRequest, plugin, nullptr);
  WebKitSecurityManager* security = webkit_web_context_get_security_manager(plugin->context);
  webkit_security_manager_register_uri_scheme_as_secure(security, "cbfolder");
  webkit_security_manager_register_uri_scheme_as_cors_enabled(security, "cbfolder");
  return plugin->context;
}

void Create(const gchar* script_channel, ChallengeBrowserPageHostApiResponseHandle* response, gpointer data) {
  auto* plugin = static_cast<Plugin*>(data);
  GtkOverlay* overlay = Overlay(plugin);
  if (!overlay) {
    return challenge_browser_page_host_api_respond_error_create(
        response, "no-overlay", "The app's runner must put Flutter's view in a GtkOverlay", nullptr);
  }
  const int64_t id = ++plugin->next_id;
  plugin->pages[id] = std::make_unique<Page>(Context(plugin), overlay, plugin->view, script_channel,
                                             [plugin, id](ChallengeBrowserPageEvent* event) {
                                               challenge_browser_page_flutter_api_on_event(plugin->events, id, event,
                                                                                           nullptr, nullptr, nullptr);
                                             });
  challenge_browser_page_host_api_respond_create(response, id);
}

ChallengeBrowserPageHostApiLoadResponse* Load(int64_t page_id, const gchar* url, FlValue* headers, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_load_response_new_error("no-page", message, nullptr);
  }
  page->Load(url, headers);
  return challenge_browser_page_host_api_load_response_new();
}

void Evaluate(int64_t page_id,
              const gchar* script,
              ChallengeBrowserPageHostApiResponseHandle* response,
              gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_respond_error_evaluate(response, "no-page", message, nullptr);
  }
  page->Evaluate(script, response);
}

ChallengeBrowserPageHostApiAddDocumentStartScriptResponse* AddDocumentStartScript(int64_t page_id,
                                                                                 const gchar* script,
                                                                                 gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_add_document_start_script_response_new_error("no-page", message, nullptr);
  }
  page->AddDocumentStartScript(script);
  return challenge_browser_page_host_api_add_document_start_script_response_new();
}

void Cookies(int64_t page_id, const gchar* url, ChallengeBrowserPageHostApiResponseHandle* response, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_respond_error_cookies(response, "no-page", message, nullptr);
  }
  page->Cookies(url, response);
}

void DeleteCookies(int64_t page_id,
                   const gchar* url,
                   const gchar* name,
                   ChallengeBrowserPageHostApiResponseHandle* response,
                   gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_respond_error_delete_cookies(response, "no-page", message, nullptr);
  }
  page->DeleteCookies(url, name, response);
}

void UserAgent(int64_t page_id, ChallengeBrowserPageHostApiResponseHandle* response, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_respond_error_user_agent(response, "no-page", message, nullptr);
  }
  challenge_browser_page_host_api_respond_user_agent(response, page->UserAgent());
}

ChallengeBrowserPageHostApiSetUserAgentResponse* SetUserAgent(int64_t page_id, const gchar* user_agent, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_set_user_agent_response_new_error("no-page", message, nullptr);
  }
  page->SetUserAgent(user_agent);
  return challenge_browser_page_host_api_set_user_agent_response_new();
}

ChallengeBrowserPageHostApiSetCaptureResponse* SetCapture(int64_t page_id, gboolean enabled, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_set_capture_response_new_error("no-page", message, nullptr);
  }
  page->SetCapture(enabled);
  return challenge_browser_page_host_api_set_capture_response_new();
}

ChallengeBrowserPageHostApiSetNavigationStopsResponse* SetNavigationStops(int64_t page_id,
                                                                        FlValue* prefixes,
                                                                        gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_set_navigation_stops_response_new_error("no-page", message, nullptr);
  }
  std::vector<std::string> stops;
  for (size_t i = 0; i < fl_value_get_length(prefixes); i++) {
    FlValue* prefix = fl_value_get_list_value(prefixes, i);
    if (fl_value_get_type(prefix) == FL_VALUE_TYPE_STRING) stops.emplace_back(fl_value_get_string(prefix));
  }
  page->SetNavigationStops(std::move(stops));
  return challenge_browser_page_host_api_set_navigation_stops_response_new();
}

ChallengeBrowserPageHostApiSetFrameResponse* SetFrame(int64_t page_id,
                                                      ChallengeBrowserPageFrame* frame,
                                                      gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_set_frame_response_new_error("no-page", message, nullptr);
  }
  page->SetFrame(frame);
  return challenge_browser_page_host_api_set_frame_response_new();
}

ChallengeBrowserPageHostApiFocusResponse* Focus(int64_t page_id, gboolean forward, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_focus_response_new_error("no-page", message, nullptr);
  }
  page->Focus(forward);
  return challenge_browser_page_host_api_focus_response_new();
}

ChallengeBrowserPageHostApiBlurResponse* Blur(int64_t page_id, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_blur_response_new_error("no-page", message, nullptr);
  }
  page->Blur();
  return challenge_browser_page_host_api_blur_response_new();
}

void Dispose(int64_t page_id, ChallengeBrowserPageHostApiResponseHandle* response, gpointer data) {
  static_cast<Plugin*>(data)->pages.erase(page_id);
  challenge_browser_page_host_api_respond_dispose(response);
}

void Tap(int64_t page_id, double x, double y, ChallengeBrowserPageHostApiResponseHandle* response, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_respond_error_tap(response, "no-page", message, nullptr);
  }
  page->Tap(x, y, response);
}

void EvaluateIsolated(int64_t page_id,
                      const gchar* script,
                      ChallengeBrowserPageHostApiResponseHandle* response,
                      gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_respond_error_evaluate_isolated(response, "no-page", message, nullptr);
  }
  page->EvaluateIsolated(script, response);
}

ChallengeBrowserPageHostApiCapabilitiesResponse* Capabilities(gpointer data) {
  g_autoptr(ChallengeBrowserPageCapabilities) capabilities = challenge_browser_page_capabilities_new(TRUE, TRUE);
  return challenge_browser_page_host_api_capabilities_response_new(capabilities);
}

ChallengeBrowserPageHostApiEngineVersionResponse* EngineVersion(gpointer data) {
  return challenge_browser_page_host_api_engine_version_response_new("");
}

void DevTools(int64_t page_id,
              const gchar* method,
              const gchar* params_json,
              ChallengeBrowserPageHostApiResponseHandle* response,
              gpointer data) {
  challenge_browser_page_host_api_respond_error_dev_tools(response, "unsupported", "DevTools calls are for Windows only",
                                                          nullptr);
}

ChallengeBrowserPageHostApiServeFolderResponse* ServeFolder(int64_t page_id,
                                                             const gchar* name,
                                                             const gchar* folder,
                                                             gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_serve_folder_response_new_error("no-page", message, nullptr);
  }
  return challenge_browser_page_host_api_serve_folder_response_new(page->ServeFolder(name, folder).c_str());
}

ChallengeBrowserPageHostApiHoldDialogsResponse* HoldDialogs(int64_t page_id, gboolean hold, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_hold_dialogs_response_new_error("no-page", message, nullptr);
  }
  page->HoldDialogs(hold);
  return challenge_browser_page_host_api_hold_dialogs_response_new();
}

ChallengeBrowserPageHostApiAnswerDialogResponse* AnswerDialog(int64_t page_id,
                                                               int64_t dialog_id,
                                                               gboolean accept,
                                                               const gchar* text,
                                                               gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_answer_dialog_response_new_error("no-page", message, nullptr);
  }
  page->AnswerDialog(dialog_id, accept, text);
  return challenge_browser_page_host_api_answer_dialog_response_new();
}

ChallengeBrowserPageHostApiTitleResponse* Title(int64_t page_id, gpointer data) {
  Page* page = Find(static_cast<Plugin*>(data), page_id);
  if (!page) {
    g_autofree gchar* message = NoPage(page_id);
    return challenge_browser_page_host_api_title_response_new_error("no-page", message, nullptr);
  }
  return challenge_browser_page_host_api_title_response_new(page->Title());
}

const ChallengeBrowserPageHostApiVTable kHostApi = {
    .create = Create,
    .load = Load,
    .evaluate = Evaluate,
    .add_document_start_script = AddDocumentStartScript,
    .cookies = Cookies,
    .delete_cookies = DeleteCookies,
    .user_agent = UserAgent,
    .set_user_agent = SetUserAgent,
    .set_capture = SetCapture,
    .set_frame = SetFrame,
    .focus = Focus,
    .blur = Blur,
    .set_navigation_stops = SetNavigationStops,
    .dispose = Dispose,
    .tap = Tap,
    .evaluate_isolated = EvaluateIsolated,
    .capabilities = Capabilities,
    .engine_version = EngineVersion,
    .dev_tools = DevTools,
    .serve_folder = ServeFolder,
    .hold_dialogs = HoldDialogs,
    .answer_dialog = AnswerDialog,
    .title = Title,
};

}  // namespace

void challenge_browser_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  auto* plugin = new Plugin{fl_plugin_registrar_get_view(registrar), challenge_browser_page_flutter_api_new(messenger, nullptr)};
  challenge_browser_page_host_api_set_method_handlers(messenger, nullptr, &kHostApi, plugin,
                                                      [](gpointer data) { delete static_cast<Plugin*>(data); });
}
