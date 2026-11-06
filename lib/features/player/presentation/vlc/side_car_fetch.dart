/// How the player reads a subtitle file: from this device, or over the
/// network with the headers it came with.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/dio_client_provider.dart';
import '../../domain/side_car_subtitles.dart';

/// How long a subtitle file may take to arrive.
const Duration _kTimeout = Duration(seconds: 20);

/// The most of a subtitle file that is read. Files run to kilobytes, a large
/// SubStation Alpha script with styling to a few megabytes.
const int _kMaxBytes = 16 * 1024 * 1024;

/// The fetch [SideCarSubtitles] reads files with. A provider so a test can
/// serve files from memory.
final sideCarFetchProvider = Provider<SideCarFetch>((ref) {
  final dio = ref.watch(dioClientProvider);
  return (url, headers) => fetchSideCar(dio, url, headers);
});

/// Reads the subtitle file at [url] - a `file:` one from this device, an
/// `http(s):` one with [dio] and [headers] - or null when it cannot be had.
Future<List<int>?> fetchSideCar(
  Dio dio,
  Uri url,
  Map<String, String>? headers,
) async {
  if (url.scheme == 'file') {
    try {
      return await File.fromUri(url).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }
  if (!url.scheme.startsWith('http')) return null;
  final cancel = CancelToken();
  try {
    final response = await dio.getUri<List<int>>(
      url,
      cancelToken: cancel,
      options: Options(
        headers: headers,
        responseType: ResponseType.bytes,
        receiveTimeout: _kTimeout,
        sendTimeout: _kTimeout,
      ),
      // An address that turns out to be a video is abandoned rather than read
      // into memory whole.
      onReceiveProgress: (received, _) {
        if (received > _kMaxBytes) cancel.cancel();
      },
    );
    return response.data;
  } catch (_) {
    return null;
  }
}
