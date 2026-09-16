import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../mpv/player/player_native.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import 'controller.dart';

class LiveSubtitleSyncControl extends StatelessWidget {
  const LiveSubtitleSyncControl({super.key, required this.player});
  final PlayerNative player;

  @override
  Widget build(BuildContext context) {
    if ((!Platform.isMacOS && !Platform.isWindows) || player.audioOnly) return const SizedBox.shrink();
    final controller = LiveSubtitleSyncController.forPlayer(player);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final label = switch (controller.phase) {
          LiveSyncPhase.off => t.liveSubtitleSync.off,
          LiveSyncPhase.loadingSubtitles => t.liveSubtitleSync.loadingSubtitles,
          LiveSyncPhase.downloading => t.liveSubtitleSync.downloading,
          LiveSyncPhase.analyzing => t.liveSubtitleSync.analyzing,
          LiveSyncPhase.synced => t.liveSubtitleSync.synced,
          LiveSyncPhase.resyncing => t.liveSubtitleSync.resyncing,
          LiveSyncPhase.unable => t.liveSubtitleSync.unable,
          LiveSyncPhase.unsupported => t.liveSubtitleSync.unsupported,
        };
        final reason = switch (controller.reason) {
          null => null,
          LiveSyncReason.platform => t.liveSubtitleSync.platform,
          LiveSyncReason.englishTracks => t.liveSubtitleSync.englishTracks,
          LiveSyncReason.externalSrt => t.liveSubtitleSync.externalSrt,
          LiveSyncReason.passthrough => t.liveSubtitleSync.passthrough,
          LiveSyncReason.surround => t.liveSubtitleSync.surround,
          LiveSyncReason.source => t.liveSubtitleSync.source,
          LiveSyncReason.model => t.liveSubtitleSync.model,
          LiveSyncReason.nativeRuntime => t.liveSubtitleSync.nativeRuntime,
          LiveSyncReason.noMatch => t.liveSubtitleSync.noMatch,
        };
        final progress = controller.modelProgress;
        final detail = controller.phase == LiveSyncPhase.loadingSubtitles
            ? t.liveSubtitleSync.loadingSubtitlesDetail
            : controller.phase == LiveSyncPhase.downloading && progress != null
            ? '${(progress.receivedBytes / 1000000).toStringAsFixed(1)} / ${(progress.totalBytes / 1000000).toStringAsFixed(1)} MB'
            : (reason ??
                  (controller.automaticOffset == null
                      ? t.liveSubtitleSync.modelSize(
                          size: (LiveSubtitleSyncController.preferredModel.bytes / 1000000).ceil(),
                        )
                      : t.liveSubtitleSync.offset(seconds: controller.automaticOffset!.toStringAsFixed(2))));
        return FocusableListTile(
          leading: AppIcon(Symbols.sync_rounded, fill: 1),
          title: Text(t.liveSubtitleSync.title),
          subtitle: Text('$label\n$detail'),
          trailing: Icon(
            controller.enabled ? Symbols.toggle_on_rounded : Symbols.toggle_off_rounded,
            color: controller.enabled ? Theme.of(context).colorScheme.primary : null,
            size: 36,
          ),
          onTap: () =>
              unawaited((controller.enabled ? controller.disable() : controller.enable()).catchError((Object _) {})),
        );
      },
    );
  }
}
