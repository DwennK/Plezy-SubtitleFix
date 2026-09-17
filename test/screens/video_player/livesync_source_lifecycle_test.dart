import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/player/player_base.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/providers/shader_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/scrub_preview_source.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/models/plex/plex_config.dart';
import 'package:plezy/utils/active_client_scope.dart';
import 'package:plezy/features/live_subtitle_sync/player_attachment.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/hdr_startup.dart';
import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/playback_report_fakes.dart';
import '../../test_helpers/pump.dart';
import '../../test_helpers/stub_music_playback_service.dart';

/// Exercise the real screen and PlayerNative.open reset; a domain-only source
/// test cannot detect a provider erased between session publication and open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    tmpRoot = await Directory.systemTemp.createTemp('playback_open_failure_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    await installHdrStartupHarness();
    DownloadStorageService.resetForTesting();
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  testWidgets('Plex subtitle provider survives the initial native open', (tester) async {
    final client = _StreamClient();
    final multi = testMultiServer(clients: [client]);
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
    final accountPreferences = AccountPreferencesController();
    final observer = PlaybackLaunchObserver(isCurrent: () => true);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    const mediaMethods = MethodChannel('com.edde746.os_media_controls/methods');
    const mediaEvents = MethodChannel('com.edde746.os_media_controls/events');
    messenger.setMockMethodCallHandler(mediaMethods, (call) async => null);
    messenger.setMockMethodCallHandler(mediaEvents, (call) async => null);
    messenger.setMockMethodCallHandler(windowChannel, (call) async => call.method.startsWith('is') ? false : null);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(mediaMethods, null);
      messenger.setMockMethodCallHandler(mediaEvents, null);
      tester.view.reset();
      offlineWatch.dispose();
      accountPreferences.dispose();
    });

    final navigator = GlobalKey<NavigatorState>();
    final key = GlobalKey<VideoPlayerScreenState>();
    final loadfileUrls = <String>[];
    final providersAtNativeOpen = <bool>[];

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method != 'command') return null;
        final args = (call.arguments as Map?)?['args'];
        if (args is! List || args.isEmpty || args.first != 'loadfile') return null;
        loadfileUrls.add(args[1] as String);
        providersAtNativeOpen.add(LiveSyncPlayerAttachment.subtitleProviders[key.currentState!.player!] != null);
        final player = key.currentState!.player! as PlayerBase;
        player.handlePlayerEvent('start-file', {'sourceId': loadfileUrls.length});
        player.handlePlayerEvent('file-loaded', {'sourceId': loadfileUrls.length});
        player.handlePlayerEvent('playback-restart', {'sourceId': loadfileUrls.length, 'positionSeconds': 0.0});
        return null;
      },
      testBody: () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
              ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
              ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
              ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
              ChangeNotifierProvider(create: (_) => CompanionRemoteProvider()),
              ChangeNotifierProvider(create: (_) => WatchTogetherProvider()),
              ChangeNotifierProvider(create: (_) => ShaderProvider()),
              ChangeNotifierProvider<MusicPlaybackService>(create: (_) => StubMusicPlaybackService()),
              Provider<AppDatabase>.value(value: db),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Browse')),
            ),
          ),
        );
        unawaited(
          VideoPlayerRoute(
            builder: (_) => VideoPlayerScreen(
              key: key,
              metadata: testMediaItem(
                id: 'source-lifecycle',
                serverId: 'srv-1',
                title: 'LiveSync source',
                backend: MediaBackend.plex,
              ),
              selectedQualityPreset: TranscodeQualityPreset.original,
              launchObserver: observer,
            ),
          ).push(navigator.currentState!),
        );

        await pumpUntil(
          tester,
          () =>
              key.currentState?.player != null &&
              LiveSyncPlayerAttachment.subtitleProviders[key.currentState!.player!] != null,
          describe: () => 'loadfiles=${loadfileUrls.length}, missing Plex subtitle provider after native open',
        );
        expect(loadfileUrls, hasLength(1));
        expect(providersAtNativeOpen, [false], reason: "native open must reset the previous source first");
        final active = key.currentState!.player!;
        expect(LiveSyncPlayerAttachment.subtitleProviders[active], isNotNull);

        var shutdownDone = false;
        final shutdown = PlaybackCoordinator.instance.shutdownVideo().whenComplete(() => shutdownDone = true);
        await pumpUntil(tester, () => shutdownDone);
        await shutdown;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }, skip: !Platform.isMacOS && !Platform.isWindows);
}

/// Plex metadata without real network requests or credentials.
class _StreamClient with PlaybackReportRecorder implements PlexClient {
  @override
  PlexConfig get config =>
      PlexConfig(baseUrl: 'https://example.invalid', clientIdentifier: 'fixture', product: 'Fixture', version: '1');
  @override
  PlexProfileScopeId profileScopeId = buildPlexProfileScopeId(serverId: ServerId('srv-1'), profileId: 'fixture');
  @override
  String get scopedServerId => profileScopeId;
  @override
  ServerId get serverId => ServerId('srv-1');
  @override
  String get serverName => 'Server';
  @override
  MediaBackend get backend => MediaBackend.plex;
  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;
  @override
  double get watchedThreshold => 0.9;
  @override
  bool get marksWatchedOnPlaybackStopped => true;
  @override
  Map<String, String> get streamHeaders => const {};

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async =>
      PlaybackInitializationResult(
        availableVersions: const [],
        videoUrl: 'https://example.invalid/${options.metadata.id}',
        mediaInfo: MediaSourceInfo(
          videoUrl: 'https://example.invalid/${options.metadata.id}',
          audioTracks: const [],
          subtitleTracks: [
            MediaSubtitleTrack(id: 42, codec: 'srt', languageCode: 'eng', selected: true, forced: false),
          ],
          chapters: const [],
        ),
      );

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async {}

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({
    required MediaItem item,
    required MediaSourceInfo mediaSource,
  }) async => null;

  @override
  void close() {}

  @override
  Future<void> closeGracefully({Duration drainTimeout = const Duration(seconds: 5)}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
