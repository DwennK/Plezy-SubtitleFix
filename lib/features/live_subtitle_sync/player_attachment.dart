/// Player-owned cleanup hook without importing the feature controller into mpv.
class LiveSyncPlayerAttachment {
  const LiveSyncPlayerAttachment(this.stop);
  final Future<void> Function() stop;
  static final sessions = Expando<LiveSyncPlayerAttachment>();
}
