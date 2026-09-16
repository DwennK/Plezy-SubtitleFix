import 'package:http/http.dart' as http;

import '../../mpv/models.dart';
import '../../utils/media_server_http_client.dart';
import 'subtitle_source.dart';
import 'mapping_cache.dart';

typedef LiveSyncSubtitleProvider =
    Future<SubtitleDocument?> Function(SubtitleTrack track, http.Client client, AbortController abort);

/// Player-owned cleanup hook without importing the feature controller into mpv.
class LiveSyncPlayerAttachment {
  const LiveSyncPlayerAttachment(this.stop);
  final Future<void> Function() stop;
  static final subtitleProviders = Expando<LiveSyncSubtitleProvider>();
  static final sessions = Expando<LiveSyncPlayerAttachment>();
  static final mediaIdentities = Expando<Future<LiveSyncMediaIdentity?> Function()>();
}
