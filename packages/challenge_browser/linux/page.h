#ifndef FLUTTER_PLUGIN_CHALLENGE_BROWSER_PAGE_H_
#define FLUTTER_PLUGIN_CHALLENGE_BROWSER_PAGE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "messages.g.h"

// One page: a WebKitWebView of its own, laid over Flutter's view in the GtkOverlay the app's runner
// puts around it. Flutter on Linux has no platform views, so a shown page covers the rectangle
// `ChallengeBrowserView` takes. A hidden one stays drawn, so it runs as if shown, but transparent and
// out of the way of the pointer, at a usual size.
class Page {
 public:
  Page(WebKitWebContext* context,
       GtkOverlay* overlay,
       FlView* view,
       const gchar* channel,
       std::function<void(ChallengeBrowserPageEvent*)> emit);
  ~Page();

  Page(const Page&) = delete;
  Page& operator=(const Page&) = delete;

  GtkWidget* widget() const { return GTK_WIDGET(web_view_); }
  bool shown() const { return shown_; }

  // Where the overlay puts the page, in Flutter's view.
  GdkRectangle Allocation() const { return shown_ ? frame_ : kHidden; }

  void Load(const gchar* url, FlValue* headers);
  void Evaluate(const gchar* script, ChallengeBrowserPageHostApiResponseHandle* response);

  // [script] in a script world of SkyStream's: the page's DOM, out of sight of its own scripts.
  void EvaluateIsolated(const gchar* script, ChallengeBrowserPageHostApiResponseHandle* response);

  // A click at [x], [y] CSS pixels, as the pointer's own events sent straight to the web view: a short
  // move there, then a press and a release. The page needn't be shown or focused.
  void Tap(double x, double y, ChallengeBrowserPageHostApiResponseHandle* response);
  void AddDocumentStartScript(const gchar* script);
  void Cookies(const gchar* url, ChallengeBrowserPageHostApiResponseHandle* response);
  void DeleteCookies(const gchar* url, const gchar* name, ChallengeBrowserPageHostApiResponseHandle* response);
  const gchar* UserAgent();
  void SetUserAgent(const gchar* agent);
  void SetCapture(bool enabled) { capturing_ = enabled; }

  // Main-frame URLs starting with one of [prefixes] are stopped and reported, not loaded.
  void SetNavigationStops(std::vector<std::string> prefixes) { navigation_stops_ = std::move(prefixes); }

  // Serves [folder] read-only at cbfolder://[name]/ (Phase 7c's §6) and returns that base: this page's own.
  std::string ServeFolder(const gchar* name, const gchar* folder);

  // Answers [request], one of this page's cbfolder:// requests, with the file it names in its folder, or an error.
  void Serve(WebKitURISchemeRequest* request);

  // Holds the page's dialogs while [hold], reporting each, until AnswerDialog; else WebKitGTK shows its own.
  void HoldDialogs(bool hold) { holds_dialogs_ = hold; }

  // Answers held dialog [id]: a confirm [accept]s, a prompt answers [text] when [accept], else null.
  void AnswerDialog(int64_t id, bool accept, const gchar* text);

  // The page's title as WebKitGTK has it, or null: nothing runs in the page, which may be waiting in a held dialog.
  const gchar* Title() const { return webkit_web_view_get_title(web_view_); }

  // Shows the page over [frame], in logical pixels from the top left of Flutter's view, or hides
  // it again when [frame] is null.
  void SetFrame(ChallengeBrowserPageFrame* frame);

  // Moves keyboard focus into the page: to its first control, or its last when going back.
  void Focus(bool forward);

  // Gives keyboard focus back to Flutter's view, if the page has it.
  void Blur();

  // Tab is leaving the page, which has keyboard focus: Flutter's view takes it back.
  void Leave(GtkDirectionType direction);

 private:
  static constexpr GdkRectangle kHidden = {0, 0, 1024, 768};

  void Hide();
  void Emit(ChallengeBrowserPageEvent* event);
  WebKitCookieManager* CookieManager();

  static void OnLoadChanged(WebKitWebView* web_view, WebKitLoadEvent load_event, Page* self);
  static gboolean OnDecidePolicy(WebKitWebView* web_view,
                                 WebKitPolicyDecision* decision,
                                 WebKitPolicyDecisionType type,
                                 Page* self);

  // Whether [uri] is one of the navigation stops: if so, reports it, and the caller stops it.
  bool Stopped(const gchar* uri);
  static gboolean OnLoadFailed(WebKitWebView* web_view,
                               WebKitLoadEvent load_event,
                               const gchar* uri,
                               GError* error,
                               Page* self);
  static void OnProgress(WebKitWebView* web_view, GParamSpec* spec, Page* self);
  static void OnTerminated(WebKitWebView* web_view, WebKitWebProcessTerminationReason reason, Page* self);
  static void OnResourceLoadStarted(WebKitWebView* web_view,
                                    WebKitWebResource* resource,
                                    WebKitURIRequest* request,
                                    Page* self);
  static void OnScriptMessage(WebKitUserContentManager* content, WebKitJavascriptResult* result, Page* self);
  static gboolean OnFocusIn(GtkWidget* widget, GdkEventFocus* event, Page* self);
  static gboolean OnFocusOut(GtkWidget* widget, GdkEventFocus* event, Page* self);
  static gboolean OnKey(GtkWidget* widget, GdkEventKey* event, Page* self);
  static gboolean OnScriptDialog(WebKitWebView* web_view, WebKitScriptDialog* dialog, Page* self);

  GtkOverlay* overlay_;
  FlView* view_;
  WebKitUserContentManager* content_;
  WebKitWebView* web_view_;
  std::function<void(ChallengeBrowserPageEvent*)> emit_;
  GdkRectangle frame_ = kHidden;
  bool shown_ = false;
  bool capturing_ = false;
  std::vector<std::string> navigation_stops_;

  // Its served folders, by name.
  std::map<std::string, std::string> folders_;

  // Whether its dialogs wait for Dart, and those that do, by id: each holds a reference.
  bool holds_dialogs_ = false;
  std::map<int64_t, WebKitScriptDialog*> dialogs_;
  int64_t next_dialog_ = 0;

  // The current load failed: it finishes without a page.
  bool failed_ = false;

  // A focus request that came before the page was shown: forward or backward.
  std::optional<bool> pending_focus_;
};

#endif  // FLUTTER_PLUGIN_CHALLENGE_BROWSER_PAGE_H_
