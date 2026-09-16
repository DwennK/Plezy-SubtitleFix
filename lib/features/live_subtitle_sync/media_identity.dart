import '../../services/playback_session.dart';
import 'mapping_cache.dart';

/// Use the selected physical version, never the temporary playback URL.
LiveSyncMediaIdentity? liveSyncIdentityForSession(PlaybackSession session) {
  if (session.isOffline || session.isTranscoding) return null;
  final versions = session.availableVersions;
  final sourceId = session.mediaInfo?.mediaSourceId ?? session.mediaSourceId;
  final version = sourceId != null
      ? versions.where((version) => version.id == sourceId).firstOrNull
      : session.mediaIndex >= 0 && session.mediaIndex < versions.length
      ? versions[session.mediaIndex]
      : null;
  if (version == null) return null;
  final partId = session.mediaInfo?.partId?.toString();
  final partIndex = session.mediaInfo?.partIndex ?? 0;
  final part = partId != null
      ? version.parts.where((part) => part.id == partId).firstOrNull
      : partIndex >= 0 && partIndex < version.parts.length
      ? version.parts[partIndex]
      : null;
  if (part == null) return null;
  return LiveSyncMediaIdentity.server(
    server: session.metadata.serverId,
    item: session.metadata.id,
    version: version.id,
    part: part.id,
    updatedAt: session.metadata.updatedAt,
    sizeBytes: part.sizeBytes,
    durationMs: part.durationMs ?? session.metadata.durationMs,
  );
}
