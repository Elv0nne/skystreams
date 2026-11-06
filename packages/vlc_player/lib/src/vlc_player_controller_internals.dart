import 'vlc_video_geometry.dart';

/// Internal controller hooks used by `VlcPlayer`.
///
/// This file is intentionally not exported from `package:vlc_player/vlc_player.dart`.
abstract interface class VlcPlayerControllerInternals {
  /// Attaches the controller to a platform-view backed native player.
  Future<void> attach(int viewId);

  /// Attaches the controller to a texture-backed native player.
  Future<int> attachTexturePlayer();

  /// Detaches and disposes the currently attached native player.
  ///
  /// [viewId] names the view the caller owns, so a teardown that lands after
  /// its replacement has attached cannot take the live player with it.
  /// [textureId] does the same on the texture path, which never learns its
  /// view: the texture its create handed back. Both null detaches whatever is
  /// attached.
  Future<void> detach({int? viewId, int? textureId});

  /// Tells the native player the crop and aspect ratio the widget's fit needs,
  /// so libVLC draws subtitles inside the part of the picture that is shown;
  /// see [VlcVideoGeometry]. Kept, and replayed on every attach.
  void setVideoGeometry(VlcVideoGeometry geometry);
}
