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
        final strings = t.liveSubtitleSync;
        final label = switch (controller.phase) {
          LiveSyncPhase.off => strings.off,
          LiveSyncPhase.downloading => strings.downloading,
          LiveSyncPhase.analyzing => strings.analyzing,
          LiveSyncPhase.synced => strings.synced,
          LiveSyncPhase.resyncing => strings.resyncing,
          LiveSyncPhase.unable => strings.unable,
          LiveSyncPhase.unsupported => strings.unsupported,
        };
        final reason = switch (controller.reason) {
          null => null,
          LiveSyncReason.platform => strings.platform,
          LiveSyncReason.englishTracks => strings.englishTracks,
          LiveSyncReason.externalSrt => strings.externalSrt,
          LiveSyncReason.passthrough => strings.passthrough,
          LiveSyncReason.surround => strings.surround,
          LiveSyncReason.source => strings.source,
          LiveSyncReason.model => strings.model,
          LiveSyncReason.nativeRuntime => strings.nativeRuntime,
          LiveSyncReason.noMatch => strings.noMatch,
        };
        final progress = controller.modelProgress;
        final detail = controller.phase == LiveSyncPhase.downloading && progress != null
            ? '${(progress.receivedBytes / 1000000).toStringAsFixed(1)} / ${(progress.totalBytes / 1000000).toStringAsFixed(1)} MB'
            : (reason ??
                  (controller.automaticOffset == null
                      ? strings.modelSize
                      : strings.offset(seconds: controller.automaticOffset!.toStringAsFixed(2))));
        return FocusableListTile(
          leading: AppIcon(Symbols.sync_rounded, fill: 1),
          title: Text(strings.title),
          subtitle: Text('$label\n$detail'),
          trailing: Icon(
            controller.enabled ? Icons.toggle_on : Icons.toggle_off,
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
