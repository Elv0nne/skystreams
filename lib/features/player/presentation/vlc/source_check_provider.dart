import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/source_check.dart';
import '../../domain/stream_resolver.dart';

/// How the player checks a source after a failure (spec 2). A provider, as
/// `sideCarFetchProvider` is, so a screen test can answer for the server.
final sourceCheckProvider = Provider<SourceCheck>((ref) => checkSource);
