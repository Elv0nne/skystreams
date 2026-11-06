import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The desktop texture teardown, pinned as source order.
///
/// Neither of these plugins is built by any CI machine, and the bug they
/// carried - freeing the pixel buffers before retiring the texture, so the
/// compositor read a freed block and the app vanished as the user pressed
/// Back - is invisible to every Dart-level test in this package: it lives
/// entirely in the order of four statements. So the order is what is asserted
/// here, in the two functions that own it.
void main() {
  group('Windows plugin teardown', () {
    late String disposeCore;
    late String releaseTextureMemory;
    late String copyPixelBuffer;

    setUpAll(() {
      final source = _fileText('windows/vlc_player_plugin.cpp');
      disposeCore = _functionBody(source, 'void DisposeCore()');
      releaseTextureMemory = _functionBody(source, 'void ReleaseTextureMemory()');
      copyPixelBuffer = _functionBody(
        source,
        'const FlutterDesktopPixelBuffer *CopyPixelBuffer(size_t width,',
      );
    });

    test('stops libVLC before it retires the texture', () {
      expect(
        disposeCore.indexOf('core_->Dispose()'),
        lessThan(disposeCore.indexOf('UnregisterTexture')),
        reason: 'The blocking stop must not run on the raster thread, which '
            'is where the unregister completion callback lands.',
      );
    });

    test('never frees the core in the dispose itself', () {
      // The free belongs to the unregister completion callback, which the
      // registrar runs on the raster thread once no populate can be in
      // flight. A core_.reset() here is the use-after-free coming back.
      expect(disposeCore, isNot(contains('core_.reset()')));
      expect(disposeCore, isNot(contains('texture_.reset()')));
    });

    test('retires the texture before it releases the memory the texture reads',
        () {
      final unregisterWithCallback = disposeCore.indexOf(
        'texture_registrar_->UnregisterTexture(\n'
        '          texture_id, [self] { self->ReleaseTextureMemory(); });',
      );
      expect(
        unregisterWithCallback,
        isNonNegative,
        reason: 'The completion-callback overload is the only signal that the '
            'engine has finished with the buffer CopyPixelBuffer handed out.',
      );
      // The fallback path - no shared owner, i.e. engine teardown - still has
      // to unregister before it frees.
      final lastUnregister = disposeCore.lastIndexOf('UnregisterTexture');
      final release = disposeCore.lastIndexOf('ReleaseTextureMemory()');
      expect(lastUnregister, lessThan(release));
    });

    test('frees the core under the frame lock', () {
      expect(
        releaseTextureMemory.indexOf('lock(frame_mutex_)'),
        lessThan(releaseTextureMemory.indexOf('core_.reset()')),
      );
      expect(releaseTextureMemory, contains('texture_.reset()'));
    });

    test('reads the core under the frame lock, and takes no other lock there',
        () {
      expect(
        copyPixelBuffer.indexOf('lock(frame_mutex_)'),
        lessThan(copyPixelBuffer.indexOf('core_->CopyPixels')),
      );
      // lifecycle_mutex_ is held across libVLC's stop; taking it here would
      // stall the raster thread for the whole shutdown.
      expect(copyPixelBuffer, isNot(contains('lifecycle_mutex_')));
    });

    test('updates come from the pump, not a 500 ms poll', () {
      final source = _fileText('windows/vlc_player_plugin.cpp');
      expect(source, isNot(contains('sleep_for(std::chrono::milliseconds(500))')));
      expect(source, contains('VlcUpdatePump'));
      expect(disposeCore.indexOf('updates_->Stop()'), isNonNegative);
      expect(
        disposeCore.indexOf('updates_->Stop()'),
        lessThan(disposeCore.indexOf('core_->Dispose()')),
      );
    });

    test('setSource hands the core keepPicture, and the first player keeps '
        'the plugin bank', () {
      final source = _fileText('windows/vlc_player_plugin.cpp');
      expect(source, contains('ReadBool(*arguments, "keepPicture")'));
      expect(source, contains('KeepPluginBankLoaded('));
    });
  });

  group('Linux plugin teardown', () {
    late String dispose;
    late String copyPixels;

    setUpAll(() {
      final source = _fileText('linux/vlc_player_plugin.cc');
      dispose = _functionBody(source, 'void Dispose()');
      copyPixels = _functionBody(
        source,
        'gboolean vlc_pixel_buffer_texture_copy_pixels(FlPixelBufferTexture* '
        'texture,',
      );
    });

    test('stops libVLC, retires the texture, closes the read path, then frees',
        () {
      final stop = dispose.indexOf('core_->Dispose()');
      final unregister =
          dispose.indexOf('fl_texture_registrar_unregister_texture');
      final closeReadPath = dispose.indexOf('texture_->player = nullptr');
      final free = dispose.indexOf('core_.reset()');

      expect(stop, isNonNegative);
      expect(unregister, greaterThan(stop));
      expect(closeReadPath, greaterThan(unregister));
      expect(free, greaterThan(closeReadPath));
    });

    test('clears the texture player under its mutex', () {
      final lock = dispose.indexOf('g_mutex_lock(&texture_->player_mutex)');
      final clear = dispose.indexOf('texture_->player = nullptr');
      final unlock = dispose.indexOf('g_mutex_unlock(&texture_->player_mutex)');

      expect(lock, isNonNegative);
      expect(clear, greaterThan(lock));
      expect(unlock, greaterThan(clear));
      expect(
        dispose.indexOf('g_clear_object(&texture_)'),
        greaterThan(unlock),
      );
    });

    test('holds the texture mutex across the whole read, not just the load',
        () {
      final lock = copyPixels.indexOf('g_mutex_lock(&self->player_mutex)');
      final read = copyPixels.indexOf('self->player->CopyPixels(');
      final unlock = copyPixels.indexOf('g_mutex_unlock(&self->player_mutex)');

      expect(lock, isNonNegative);
      expect(read, greaterThan(lock));
      expect(unlock, greaterThan(read));
    });

    test('updates come from the pump, not a 500 ms poll', () {
      final source = _fileText('linux/vlc_player_plugin.cc');
      expect(source, isNot(contains('sleep_for(std::chrono::milliseconds(500))')));
      expect(source, contains('VlcUpdatePump'));
      expect(dispose.indexOf('updates_->Stop()'), isNonNegative);
      expect(
        dispose.indexOf('updates_->Stop()'),
        lessThan(dispose.indexOf('core_->Dispose()')),
        reason: 'no update may read the core while it goes',
      );
    });

    test('setSource hands the core keepPicture', () {
      final source = _fileText('linux/vlc_player_plugin.cc');
      expect(source, contains('ReadBool(arguments, "keepPicture")'));
    });
  });

  for (final platform in <String>['ios', 'macos']) {
    group('$platform plugin teardown', () {
      late String source;
      late String dispose;

      setUpAll(() {
        source = _fileText(
          '$platform/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
        );
        dispose = _functionBody(source, 'func dispose()');
      });

      test('lets the last reference to the player go off the main thread',
          () {
        // VLCKit's dealloc waits for the stream an asynchronous stop began
        // stopping: 130 s on a stalled HLS download, on whichever thread
        // drops the last reference. macOS retires its players one at a time:
        // retire stops each and hands it to releaseLater (FORK.md 32).
        final release = platform == 'macos' ? 'retire(' : 'releaseLater(';
        expect(dispose, contains('mediaPlayer = nil'));
        expect(dispose, contains(release));
        if (platform == 'ios') {
          expect(dispose.indexOf('stop()'), lessThan(dispose.indexOf(release)));
        }
        expect(
          dispose.indexOf('textureRenderer?.detach()'),
          lessThan(dispose.indexOf('mediaPlayer = nil')),
        );
      });

      test('gives a source after the first a fresh player', () {
        // VLCKit 3.7.4 starts a media set with set_media_async only once the
        // old input has closed (patch 0023), and a stalled HLS segment kept
        // that close waiting for as long as the stall: a reconnect from a
        // stalled stream could not start.
        final setSource = _functionBody(source, 'func setSource(');
        expect(setSource, contains('replacePlayer()'));
        expect(
          setSource.indexOf('replacePlayer()'),
          lessThan(setSource.indexOf('mediaPlayer.media = media')),
        );
        final replace = _functionBody(source, 'private func replacePlayer()');
        expect(replace, contains('VLCMediaPlayer(library:'));
        expect(replace, contains('textureRenderer?.attach(to: next)'));
        // macOS stops the old player in retire, after the ones before it.
        final stop = platform == 'macos' ? 'Self.retire(old)' : 'old.stop()';
        expect(
          replace.indexOf('old.delegate = nil'),
          lessThan(replace.indexOf(stop)),
        );
        expect(
          replace.indexOf('mediaPlayer = next'),
          lessThan(
            replace.indexOf(platform == 'macos' ? 'retire(' : 'releaseLater('),
          ),
        );
      });

      test('makes players on libVLC instances kept for the process', () {
        // A released player must never end its libVLC instance: the end
        // saves libVLC's configuration under a read lock it takes twice, and
        // macOS's lock queues readers behind a writer (the audio output
        // writes the configuration at every start and close), so a release
        // off the main thread could deadlock with any of them.
        expect(source, contains('VLCMediaPlayer(library:'));
        expect(source, isNot(contains('VLCMediaPlayer(options:')));
      });
    });
  }

  test('iOS gives the audio session up only once the player is gone', () {
    final source = _fileText(
      'ios/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
    );
    final dispose = _functionBody(source, 'func dispose()');
    expect(dispose, isNot(contains('relinquishAudioSession()')));
    expect(dispose, contains('VlcAudioSession.shared.relinquish()'));
  });

  test("Android holds a replaced player's layout at its size before it "
      'stops', () {
    // libvlc-android's layout listener answers a resize - a rotation,
    // picture-in-picture - by calling into libVLC on the main thread when the
    // player has no picture size yet, behind the input lock its stop holds
    // (FORK.md 29).
    final source = _fileText(
      'android/src/main/kotlin/com/lingjhf/vlc_player/'
      'VlcPlayerPlatformView.kt',
    );
    final replace = _functionBody(source, 'private fun replacePlayer()');
    final pin = replace.indexOf('videoLayout?.let(::pinSize)');
    expect(pin, isNonNegative);
    expect(pin, lessThan(replace.indexOf('retired.stop()')));
    expect(
      _functionBody(source, 'private fun pinSize('),
      contains('FrameLayout.LayoutParams(width, height)'),
    );
  });

  test('Android tells libVLC of a lost view only while no stop holds its '
      'player', () {
    // libvlc-android's listener turns the video off at once, on the main
    // thread, and that waits for the input lock a stopping player's stop
    // holds while it joins a read that hangs: the app stopped responding as
    // it left a stream it had switched away from (FORK.md 29).
    final source = _fileText(
      'android/src/main/kotlin/com/lingjhf/vlc_player/'
      'VlcPlayerPlatformView.kt',
    );
    final destroyed = _functionBody(
      source,
      'override fun onSurfaceTextureDestroyed(',
    );
    expect(
      destroyed,
      contains('if (keeper.tellsLibVlc) libVlc.onSurfaceTextureDestroyed('),
    );
    for (final (signature, player) in const [
      ('private fun replacePlayer()', 'retired'),
      ('override fun dispose()', 'player'),
    ]) {
      final body = _functionBody(source, signature);
      final stopping = body.indexOf(
        'surfaceKeepers[$player]?.playerStopping()',
      );
      expect(stopping, isNonNegative, reason: signature);
      expect(
        stopping,
        lessThan(body.indexOf('$player.stop()')),
        reason: signature,
      );
    }
  });
}

String _fileText(String path) => File(path).readAsStringSync();

/// The body of the function whose declaration starts with [signature],
/// brace-matched so a nested lambda cannot end it early.
String _functionBody(String source, String signature) {
  final declaration = source.indexOf(signature);
  if (declaration == -1) {
    fail('Could not find $signature.');
  }
  final start = source.indexOf('{', declaration);
  if (start == -1) {
    fail('Could not find the opening brace of $signature.');
  }

  var depth = 0;
  for (var index = start; index < source.length; index += 1) {
    final char = source.codeUnitAt(index);
    if (char == 0x7b) {
      depth += 1;
    } else if (char == 0x7d) {
      depth -= 1;
      if (depth == 0) {
        return source.substring(start, index + 1);
      }
    }
  }

  fail('Could not find the closing brace of $signature.');
}
