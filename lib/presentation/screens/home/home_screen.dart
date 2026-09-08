import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../state/auth_controller.dart';
import '../../state/connectivity_controller.dart';
import '../../state/providers.dart';
import '../../widgets/aurora_refresh.dart';
import '../../widgets/glass.dart';
import '../../widgets/section_carousel.dart';
import '../settings/settings_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forYou = ref.watch(forYouProvider);
    final trending = ref.watch(trendingProvider);
    final charts = ref.watch(topChartsProvider);
    final recent = ref.watch(recentlyPlayedProvider);
    final quickDownloads = ref.watch(quickDownloadsProvider);
    final online = ref.watch(isOnlineProvider);
    final user = ref.watch(authStateProvider).valueOrNull;
    final text = Theme.of(context).textTheme;

    return AuroraRefresh(
      onRefresh: () async {
        ref.read(musicRepositoryProvider).invalidateRecommendationCaches();
        ref.invalidate(forYouProvider);
        ref.invalidate(trendingProvider);
        ref.invalidate(topChartsProvider);
        ref.invalidate(quickDownloadsProvider);
        ref.invalidate(recentlyPlayedProvider);
        await Future.wait([
          ref.read(forYouProvider.future),
          ref.read(trendingProvider.future),
        ]);
      },
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 156,
            backgroundColor: AppColors.voidBlack,
            surfaceTintColor: Colors.transparent,
            leadingWidth: 64,
            leading: Padding(
              padding: const EdgeInsets.only(left: Sp.lg),
              child: Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SettingsScreen())),
                  child: _ProfileAvatar(user: user),
                ),
              ),
            ),
            title: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: Sp.sm),
                child: Text('Aurora',
                    style: text.titleLarge?.copyWith(
                        color: AppColors.accentBright,
                        fontWeight: FontWeight.w800)),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              background: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.lg, 44, Sp.lg, Sp.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Eyebrow: icon + weekday/date.
                      Row(children: [
                        Icon(_greetIcon(),
                            size: 15, color: AppColors.accentBright),
                        const SizedBox(width: 6),
                        Text(_todayLabel().toUpperCase(),
                            style: text.labelSmall?.copyWith(
                                color: AppColors.textTertiary,
                                letterSpacing: 1.6,
                                fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 2),
                      // Greeting with a soft white→accent gradient.
                      ShaderMask(
                        shaderCallback: (b) => const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.textPrimary,
                            AppColors.accentBright,
                          ],
                        ).createShader(b),
                        child: Text(_greeting(),
                            style: text.displayLarge?.copyWith(
                                letterSpacing: -1, color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!online) const SliverToBoxAdapter(child: _OfflineSanctuary()),
          const SliverToBoxAdapter(child: SizedBox(height: Sp.sm)),
          SliverToBoxAdapter(
            child: SectionCarousel(
              title: 'For you',
              data: forYou,
              cardSize: 168,
              emptyTitle: 'Nothing picked yet',
              emptySubtitle: 'Listen to a few tracks and we\'ll learn your taste.',
              onRetry: () => ref.invalidate(forYouProvider),
            ),
          ),
          SliverToBoxAdapter(
            child: SectionCarousel(
              title: 'Trending now',
              data: trending,
              cardSize: 168,
              emptyTitle: 'No trends right now',
              emptySubtitle: 'Pull down to refresh in a moment.',
              onRetry: () => ref.invalidate(trendingProvider),
            ),
          ),
          SliverToBoxAdapter(
            child: SectionCarousel(
              title: '🔥 Top Charts',
              data: charts,
              cardSize: 168,
              emptyTitle: 'Charts are empty',
              emptySubtitle: 'Nothing came back from the server.',
              onRetry: () => ref.invalidate(topChartsProvider),
            ),
          ),
          SliverToBoxAdapter(
            child: SectionCarousel(
              title: 'Recently played',
              data: recent,
              cardSize: 140,
              emptyTitle: 'Nothing here yet',
              emptySubtitle:
                  'Start listening and your recent tracks land here.',
              onRetry: () => ref.invalidate(recentlyPlayedProvider),
            ),
          ),
          SliverToBoxAdapter(
            child: SectionCarousel(
              title: 'Quick downloads',
              data: quickDownloads,
              cardSize: 140,
              emptyTitle: 'Nothing to download',
              emptySubtitle: 'Suggestions appear once For you loads.',
              onRetry: () => ref.invalidate(quickDownloadsProvider),
            ),
          ),
          // Bottom padding so content clears mini-player + nav bar.
          const SliverToBoxAdapter(child: SizedBox(height: 180)),
        ],
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.user});

  final User? user;

  @override
  Widget build(BuildContext context) {
    final providerPhoto = user?.providerData
        .where((profile) => profile.providerId == 'google.com')
        .map((profile) => profile.photoURL)
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .firstOrNull;
    final photoUrl =
        (user?.photoURL?.isNotEmpty ?? false) ? user!.photoURL : providerPhoto;
    final displayName = user?.displayName?.trim() ?? '';
    final fallback = displayName.isNotEmpty
        ? displayName.characters.first.toUpperCase()
        : null;

    return Container(
      width: 34,
      height: 34,
      padding: const EdgeInsets.all(1.5),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.accentSweep,
      ),
      child: ClipOval(
        child: photoUrl != null && photoUrl.isNotEmpty
            ? Image.network(
                photoUrl,
                key: ValueKey(photoUrl),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallback(fallback),
              )
            : _fallback(fallback),
      ),
    );
  }

  Widget _fallback(String? initial) => ColoredBox(
        color: AppColors.elevated,
        child: Center(
          child: initial != null
              ? Text(
                  initial,
                  style: const TextStyle(
                    color: AppColors.accentBright,
                    fontWeight: FontWeight.w800,
                  ),
                )
              : const Icon(Icons.person_rounded,
                  color: AppColors.accentBright, size: 20),
        ),
      );
}

String _greeting() {
  final h = DateTime.now().hour;
  if (h < 5) return 'Good night';
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  if (h < 21) return 'Good evening';
  return 'Good night';
}

IconData _greetIcon() {
  final h = DateTime.now().hour;
  if (h < 5 || h >= 21) return Icons.nightlight_round;
  if (h < 12) return Icons.wb_twilight_rounded;
  if (h < 17) return Icons.wb_sunny_rounded;
  return Icons.nights_stay_rounded;
}

String _todayLabel() {
  final n = DateTime.now();
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mons = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return '${days[n.weekday - 1]}, ${mons[n.month - 1]} ${n.day}';
}

/// Breathing offline indicator near the header.
class _OfflineSanctuary extends StatefulWidget {
  const _OfflineSanctuary();
  @override
  State<_OfflineSanctuary> createState() => _OfflineSanctuaryState();
}

class _OfflineSanctuaryState extends State<_OfflineSanctuary>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.lg, Sp.sm, Sp.lg, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Glass(
          radius: Radii.rPill,
          padding:
              const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeTransition(
                opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
                child: const Icon(Icons.cloud_off_rounded,
                    size: 16, color: AppColors.accentBright),
              ),
              const SizedBox(width: Sp.sm),
              Text('Offline Sanctuary',
                  style:
                      text.labelLarge?.copyWith(color: AppColors.textPrimary)),
              const SizedBox(width: Sp.xs),
              Text('· downloads only', style: text.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}
