import 'package:flutter/widgets.dart';

/// A second step of the side panel: a page opened from a row of one of its
/// tabs and drawn in the panel's own place, under a title and a Back button,
/// until Back.
///
/// There are two, both from the Subtitles tab. Online subtitle search used
/// to be a full-screen dialog, which took the picture away to look for its
/// subtitles and opened on a remote with nothing focused, so the arrows had
/// nowhere to go. Subtitle style restyles the subtitles while they play.
///
/// Back walks one step - the Back button, Escape, a remote's Back and
/// Android's all do - and lands focus on the row that opened the page. A tap
/// beside the drawer still closes the whole panel.
@immutable
class PanelPage {
  const PanelPage({required this.title, required this.builder});

  /// What the page's header says, beside its Back button.
  final String title;

  /// Builds the page's body. [close] takes the panel back to the tab the page
  /// was opened from, for a page that is done - a subtitle chosen and on.
  final Widget Function(BuildContext context, VoidCallback close) builder;
}
