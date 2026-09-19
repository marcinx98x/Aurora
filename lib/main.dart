import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:firebase_core/firebase_core.dart';
import 'core/config/app_config.dart';
import 'core/db/local_store.dart';
import 'core/db/sync_service.dart';
import 'core/notifications/notification_service.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'presentation/screens/root_scaffold.dart';
import 'presentation/state/providers.dart';
import 'presentation/state/player_controller.dart';
import 'presentation/state/devices_controller.dart';
import 'presentation/state/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase init failed: $e');
  }
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlay);
  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.portraitUp]);

  // Background playback: media notification + lock-screen + headset controls.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.aurora.music.channel.audio',
    androidNotificationChannelName: 'Aurora playback',
    androidNotificationOngoing: true,
    // Keep FGS between tracks — remote streams reload in Dart after EOS;
    // stopping foreground freezes that work until the user opens the app.
    androidStopForegroundOnPause: false,
  );

  final store = LocalStore();
  await store.init();

  // Resolve the backend URL from the always-on Vercel registry (the LAN IP
  // changes); fall back to the hardcoded AppConfig.apiBase if unreachable.
  await _resolveBackend();

  // Engagement notifications (daily nudges). Best-effort — never block boot.
  try {
    await NotificationService.instance.init();
    await NotificationService.instance.scheduleDailyNudges();
  } catch (_) {/* notifications optional */}

  runApp(
    ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      child: const AuroraApp(),
    ),
  );
}

Future<void> _resolveBackend() async {
  if (AppConfig.useLocalServer) return;
  // We skip Vercel registry entirely because it points to a broken server.
  // The app will now use `AppConfig.apiBase` which is populated from the environment (.env or CLI arguments).
}

class AuroraApp extends ConsumerStatefulWidget {
  const AuroraApp({super.key});

  @override
  ConsumerState<AuroraApp> createState() => _AuroraAppState();
}

class _AuroraAppState extends ConsumerState<AuroraApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(playerControllerProvider.notifier).onAppResumed());
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(playerControllerProvider.notifier).persistSessionNow());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Initialize SyncService + Aurora Connect receiver / device discovery.
    ref.read(syncServiceProvider);
    ref.watch(devicesControllerProvider);

    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Aurora Music',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      home: const RootScaffold(),
      builder: (context, child) {
        return _ReceiverBanner(child: child ?? const SizedBox.shrink());
      },
    );
  }
}

class _ReceiverBanner extends ConsumerWidget {
  final Widget child;
  const _ReceiverBanner({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controlled = ref.watch(
        devicesControllerProvider.select((s) => s.isReceiverControlled));
    final name = ref.watch(
        devicesControllerProvider.select((s) => s.controllerName));
    if (!controlled) return child;
    return Column(
      children: [
        Material(
          color: AppColors.accent.withValues(alpha: 0.92),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.cast_connected_rounded, color: Colors.black),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${name ?? 'Someone'} is controlling this device',
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref
                        .read(devicesControllerProvider.notifier)
                        .stopBeingControlled(),
                    child: const Text('Stop',
                        style: TextStyle(color: Colors.black)),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
