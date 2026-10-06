/// App-wide constants for Daily Duas.
library;

const appName = 'Daily Duas';
const appVersion = '1.0.0';

/// Built-in Gemini key, used only when the user has not entered their own key
/// (see `AppSettings.effectiveGeminiKey`). Never print or export it.
///
/// Injected at build time from the git-ignored `secrets.json`
/// (`flutter build apk --dart-define-from-file=secrets.json`, done by
/// tools/build_apk.ps1). Empty when built without it; users can still paste a
/// key in Settings.
const defaultGeminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

const defaultGeminiModels = <String>[
  'gemini-flash-latest',
  'gemini-3.8-flash',
  'gemini-3.5-flash',
  'gemini-flash-lite-latest',
  'gemini-pro-latest',
];

const anthropicModels = <String>[
  'claude-sonnet-5-5',
  'claude-haiku-4-5-20251001',
  'claude-opus-5-5',
];

/// Suggested dua categories (editor dropdown / chips), in display order.
const categories = <String>[
  'Protection',
  'Morning',
  'Evening',
  'Evil eye',
  'Anxiety',
  'Forgiveness',
  'Gratitude',
  'Sleep',
  'Travel',
  'Acceptance',
  'General',
];

/// Database file name (under `getDatabasesPath()`).
const databaseFileName = 'duas.db';

/// Backup file identity.
const backupAppId = 'daily_duas';
const backupFormat = 1;

/// Repeat count bounds for a dua.
const minRepeat = 1;
const maxRepeat = 100;

/// Arabic font size bounds (settings).
const minArabicFontSize = 20;
const maxArabicFontSize = 56;
