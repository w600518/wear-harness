import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/main_pager.dart';
import 'state/relay_session.dart';
import 'wear_m3/wear_m3.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  /*
   * A watch app owns the whole panel. The status and navigation bars are two
   * bands of black the user did not ask for, so they stay hidden and the
   * surface runs edge to edge.
   */
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  /*
   * Settings are read before the first frame so the very first render already
   * shows the saved relay address instead of the built-in default.
   */
  final settings = SettingsStore();
  await settings.load();

  runApp(DshRelayApp(settings: settings));
}

/// DSH Relay: a Wear OS client for a local DeepSeek Harness installation.
///
/// The home surface is a horizontally paged set of four cards — sessions,
/// composer, remote dsh settings, client settings. The app owns one
/// [RelaySession] above the pager so swiping between pages never drops the
/// encrypted connection or the transcript folded from it.
class DshRelayApp extends StatefulWidget {
  const DshRelayApp({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<DshRelayApp> createState() => _DshRelayAppState();
}

class _DshRelayAppState extends State<DshRelayApp> {
  late final RelaySession _session;

  @override
  void initState() {
    super.initState();
    _session = RelaySession(settings: widget.settings);
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH Relay',
      debugShowCheckedModeBanner: false,
      theme: WearTheme.dark(),
      darkTheme: WearTheme.dark(),
      // A watch is a dark device; the dark scheme is the product surface.
      themeMode: ThemeMode.dark,
      home: MainPager(session: _session),
    );
  }
}
