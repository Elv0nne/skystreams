import 'messages.g.dart' show DialogKind, FocusDirection;

/// What a page reports, as it happens. See [ChallengeBrowser.events].
sealed class BrowserEvent {
  const BrowserEvent();
}

/// The main frame started loading [url].
final class PageStarted extends BrowserEvent {
  const PageStarted(this.url);

  final Uri url;
}

/// The main frame finished loading [url].
final class PageFinished extends BrowserEvent {
  const PageFinished(this.url);

  final Uri url;
}

/// A load failed. [code] and [text] are the engine's own.
final class PageError extends BrowserEvent {
  const PageError({required this.url, required this.code, required this.text, required this.mainFrame});

  final Uri? url;
  final int code;
  final String text;
  final bool mainFrame;
}

/// Loading progress, 0 to 1.
final class PageProgress extends BrowserEvent {
  const PageProgress(this.value);

  final double value;
}

/// The page's renderer process ended. [crashed] tells a crash from the system reclaiming memory.
/// The page can't be used again: dispose it.
final class RendererGone extends BrowserEvent {
  const RendererGone({required this.crashed});

  final bool crashed;
}

/// A script in the page posted [message] to the page's channel ([ChallengeBrowser.postScript]).
final class ScriptMessage extends BrowserEvent {
  const ScriptMessage(this.message);

  final String message;
}

/// The page requested [url], while capture is on ([ChallengeBrowser.setCapture]). [method] is null
/// where the engine can't tell it.
final class CapturedRequest extends BrowserEvent {
  const CapturedRequest(this.url, {this.method});

  final Uri url;
  final String? method;
}

/// Keyboard or D-pad focus left the page towards [direction]: the shown page's widget moves Flutter's
/// focus on.
final class FocusExit extends BrowserEvent {
  const FocusExit(this.direction);

  final FocusDirection direction;
}

/// The page took keyboard focus by itself, from a click on it: the shown page's widget moves Flutter's
/// focus onto it, so Tab carries on from there.
final class PageFocused extends BrowserEvent {
  const PageFocused();
}

/// The page lost keyboard focus: to a click elsewhere, or the app losing focus. Keys reach Flutter
/// again.
final class PageBlurred extends BrowserEvent {
  const PageBlurred();
}

/// The main frame was about to go to [url], which starts with one of the page's stop prefixes
/// ([ChallengeBrowser.setNavigationStops]), and was stopped instead: a sign-in's redirect, caught
/// before it loads.
final class NavigationStopped extends BrowserEvent {
  const NavigationStopped(this.url);

  final Uri url;
}

/// A dialog the page opened, held until [ChallengeBrowser.answerDialog] while its dialogs are held
/// ([ChallengeBrowser.holdDialogs]): an alert, a confirm or a prompt, with its [message], a prompt's [defaultText], and
/// the [url] of the frame that opened it. The page's scripts wait meanwhile.
final class PageDialog extends BrowserEvent {
  const PageDialog({required this.id, required this.kind, required this.message, this.defaultText, this.url});

  final int id;
  final DialogKind kind;
  final String message;
  final String? defaultText;
  final Uri? url;
}
