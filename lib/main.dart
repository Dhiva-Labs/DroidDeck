import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers.dart';
import 'services/settings_repo.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [
        settingsRepoProvider.overrideWithValue(SettingsRepo(prefs)),
      ],
      child: const DroidDeckApp(),
    ),
  );
}

class DroidDeckApp extends StatelessWidget {
  const DroidDeckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DroidDeck',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3DDC84),
          brightness: Brightness.dark,
        ),
        visualDensity: VisualDensity.comfortable,
      ),
      home: const DroidDeckShell(),
    );
  }
}
