import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_section.dart';
import 'controller.dart';
import 'model_manager.dart';

class LiveSubtitleSyncSettings extends StatefulWidget {
  const LiveSubtitleSyncSettings({super.key, this.clearCache, this.deleteModel});
  final Future<bool> Function()? clearCache;
  final Future<void> Function()? deleteModel;

  @override
  State<LiveSubtitleSyncSettings> createState() => _LiveSubtitleSyncSettingsState();
}

class _LiveSubtitleSyncSettingsState extends State<LiveSubtitleSyncSettings> {
  bool _busy = false;

  Future<void> _remove({required bool model}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (model) {
        await (widget.deleteModel ?? LiveSubtitleSyncController.deleteSpeechModel)();
      } else if (!await (widget.clearCache ?? LiveSubtitleSyncController.clearMappingCache)()) {
        throw StateError('Mapping cache removal failed');
      }
      if (mounted) {
        showSuccessSnackBar(context, model ? t.liveSubtitleSync.modelDeleted : t.liveSubtitleSync.cacheCleared);
      }
    } on ModelException catch (error) {
      if (mounted) {
        showErrorSnackBar(
          context,
          error.reason == ModelFailure.inUse ? t.liveSubtitleSync.modelInUse : t.liveSubtitleSync.storageFailed,
        );
      }
    } catch (_) {
      if (mounted) showErrorSnackBar(context, t.liveSubtitleSync.storageFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(
    title: t.liveSubtitleSync.title,
    children: [
      FocusableListTile(
        leading: const AppIcon(Symbols.restart_alt_rounded),
        title: Text(t.liveSubtitleSync.clearCache),
        subtitle: Text(t.liveSubtitleSync.clearCacheDetail),
        enabled: !_busy,
        onTap: _busy ? null : () => _remove(model: false),
      ),
      FocusableListTile(
        leading: const AppIcon(Symbols.delete_outline_rounded),
        title: Text(t.liveSubtitleSync.deleteModel),
        subtitle: Text(t.liveSubtitleSync.deleteModelDetail),
        enabled: !_busy,
        onTap: _busy ? null : () => _remove(model: true),
      ),
    ],
  );
}
