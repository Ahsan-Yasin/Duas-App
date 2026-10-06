import 'package:flutter/material.dart';

/// Brand seed colour (deep green).
const Color appSeedColor = Color(0xFF0F6E5A);

/// Font family used for all Arabic text.
const String arabicFontFamily = 'Amiri';

/// Light and dark Material 3 themes for the app.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: appSeedColor,
      brightness: brightness,
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 2,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: scheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }
}

/// Colours for the verification chip that stay readable in both themes.
class VerificationColors {
  const VerificationColors._();

  static Color verifiedBackground(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF1E4D2B) : const Color(0xFFDDF3E1);

  static Color verifiedForeground(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFA8E6B4) : const Color(0xFF1B5E20);

  static Color unverifiedBackground(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF4D3B12) : const Color(0xFFFFF0C7);

  static Color unverifiedForeground(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFFD98A) : const Color(0xFF7A4F00);
}
