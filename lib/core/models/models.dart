import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;

import '../config.dart';
import '../util.dart';

/// Sentinel used by `copyWith` so nullable fields can be explicitly cleared:
/// `dua.copyWith(deletedAt: null)` clears, omitting the argument keeps.
const Object _unset = _Unset();

class _Unset {
  const _Unset();
}

T _pick<T>(Object? value, T current) =>
    identical(value, _unset) ? current : value as T;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is String) {
    for (final v in values) {
      if (v.name == name) return v;
    }
  }
  return fallback;
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum AudioKind { none, quran, file, tts }

enum VerificationStatus { verified, unverified }

enum CounterMode { countUp, countDown }

enum AudioMode { off, listen, listenThenRecite, followAlong }

// ---------------------------------------------------------------------------
// Dua
// ---------------------------------------------------------------------------

class Dua {
  const Dua({
    this.id,
    this.key,
    required this.title,
    required this.arabic,
    this.transliteration = '',
    this.translation = '',
    this.source = '',
    this.category = 'General',
    this.defaultRepeat = 1,
    this.audioKind = AudioKind.none,
    this.audioPath,
    this.quranSurah,
    this.quranAyahStart,
    this.quranAyahEnd,
    this.ayahs,
    this.isBuiltIn = false,
    this.verificationStatus = VerificationStatus.unverified,
    this.verificationNote = '',
    this.sortOrder = 0,
    this.createdAt = '',
    this.updatedAt = '',
    this.deletedAt,
  });

  final int? id;
  final String? key;
  final String title;
  final String arabic;
  final String transliteration;
  final String translation;
  final String source;
  final String category;

  /// 1..100
  final int defaultRepeat;
  final AudioKind audioKind;

  /// User file path for [AudioKind.file].
  final String? audioPath;
  final int? quranSurah;
  final int? quranAyahStart;
  final int? quranAyahEnd;

  /// Per-ayah Arabic (Quran duas) for follow-along highlight.
  final List<String>? ayahs;
  final bool isBuiltIn;
  final VerificationStatus verificationStatus;
  final String verificationNote;
  final int sortOrder;
  final String createdAt;
  final String updatedAt;
  final String? deletedAt;

  bool get isQuran => quranSurah != null;
  bool get isDeleted => deletedAt != null;
  bool get isVerified => verificationStatus == VerificationStatus.verified;

  Dua copyWith({
    Object? id = _unset,
    Object? key = _unset,
    String? title,
    String? arabic,
    String? transliteration,
    String? translation,
    String? source,
    String? category,
    int? defaultRepeat,
    AudioKind? audioKind,
    Object? audioPath = _unset,
    Object? quranSurah = _unset,
    Object? quranAyahStart = _unset,
    Object? quranAyahEnd = _unset,
    Object? ayahs = _unset,
    bool? isBuiltIn,
    VerificationStatus? verificationStatus,
    String? verificationNote,
    int? sortOrder,
    String? createdAt,
    String? updatedAt,
    Object? deletedAt = _unset,
  }) {
    return Dua(
      id: _pick<int?>(id, this.id),
      key: _pick<String?>(key, this.key),
      title: title ?? this.title,
      arabic: arabic ?? this.arabic,
      transliteration: transliteration ?? this.transliteration,
      translation: translation ?? this.translation,
      source: source ?? this.source,
      category: category ?? this.category,
      defaultRepeat: defaultRepeat ?? this.defaultRepeat,
      audioKind: audioKind ?? this.audioKind,
      audioPath: _pick<String?>(audioPath, this.audioPath),
      quranSurah: _pick<int?>(quranSurah, this.quranSurah),
      quranAyahStart: _pick<int?>(quranAyahStart, this.quranAyahStart),
      quranAyahEnd: _pick<int?>(quranAyahEnd, this.quranAyahEnd),
      ayahs: _pick<List<String>?>(ayahs, this.ayahs),
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      verificationNote: verificationNote ?? this.verificationNote,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: _pick<String?>(deletedAt, this.deletedAt),
    );
  }

  /// DB row (snake_case columns; ayahs as JSON text, bools as 0/1).
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'key': key,
        'title': title,
        'arabic': arabic,
        'transliteration': transliteration,
        'translation': translation,
        'source': source,
        'category': category,
        'default_repeat': defaultRepeat,
        'audio_kind': audioKind.name,
        'audio_path': audioPath,
        'quran_surah': quranSurah,
        'quran_ayah_start': quranAyahStart,
        'quran_ayah_end': quranAyahEnd,
        'ayahs': ayahs == null ? null : jsonEncode(ayahs),
        'is_built_in': isBuiltIn ? 1 : 0,
        'verification_status': verificationStatus.name,
        'verification_note': verificationNote,
        'sort_order': sortOrder,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'deleted_at': deletedAt,
      };

  factory Dua.fromMap(Map<String, Object?> m) => Dua(
        id: asInt(m['id']),
        key: asStringOrNull(m['key']),
        title: asString(m['title']),
        arabic: asString(m['arabic']),
        transliteration: asString(m['transliteration']),
        translation: asString(m['translation']),
        source: asString(m['source']),
        category: asString(m['category'], fallback: 'General'),
        defaultRepeat:
            clampInt(asInt(m['default_repeat']) ?? 1, minRepeat, maxRepeat),
        audioKind:
            _enumByName(AudioKind.values, m['audio_kind'], AudioKind.none),
        audioPath: asStringOrNull(m['audio_path']),
        quranSurah: asInt(m['quran_surah']),
        quranAyahStart: asInt(m['quran_ayah_start']),
        quranAyahEnd: asInt(m['quran_ayah_end']),
        ayahs: jsonStringList(m['ayahs']),
        isBuiltIn: asBool(m['is_built_in']),
        verificationStatus: _enumByName(VerificationStatus.values,
            m['verification_status'], VerificationStatus.unverified),
        verificationNote: asString(m['verification_note']),
        sortOrder: asInt(m['sort_order']) ?? 0,
        createdAt: asString(m['created_at']),
        updatedAt: asString(m['updated_at']),
        deletedAt: asStringOrNull(m['deleted_at']),
      );

  /// Backup JSON (native types: list for ayahs, bool for is_built_in).
  Map<String, dynamic> toJson() => {
        ...toMap(),
        'id': id,
        'ayahs': ayahs,
        'is_built_in': isBuiltIn,
      };

  /// Parses backup JSON. Throws [FormatException] when title/arabic missing.
  factory Dua.fromJson(Map<String, dynamic> j) {
    final d = Dua.fromMap(j);
    if (d.title.trim().isEmpty) {
      throw const FormatException('missing title');
    }
    if (d.arabic.trim().isEmpty) {
      throw const FormatException('missing Arabic text');
    }
    return d;
  }

  @override
  String toString() => 'Dua($id, $key, $title)';
}

// ---------------------------------------------------------------------------
// Routines
// ---------------------------------------------------------------------------

class RoutineItem {
  const RoutineItem({
    this.id,
    required this.routineId,
    required this.duaId,
    this.position = 0,
    this.repeatOverride,
  });

  final int? id;
  final int routineId;
  final int duaId;
  final int position;
  final int? repeatOverride;

  RoutineItem copyWith({
    Object? id = _unset,
    int? routineId,
    int? duaId,
    int? position,
    Object? repeatOverride = _unset,
  }) =>
      RoutineItem(
        id: _pick<int?>(id, this.id),
        routineId: routineId ?? this.routineId,
        duaId: duaId ?? this.duaId,
        position: position ?? this.position,
        repeatOverride: _pick<int?>(repeatOverride, this.repeatOverride),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'routine_id': routineId,
        'dua_id': duaId,
        'position': position,
        'repeat_override': repeatOverride,
      };

  factory RoutineItem.fromMap(Map<String, Object?> m) => RoutineItem(
        id: asInt(m['id']),
        routineId: asInt(m['routine_id']) ?? 0,
        duaId: asInt(m['dua_id']) ?? 0,
        position: asInt(m['position']) ?? 0,
        repeatOverride: asInt(m['repeat_override']),
      );

  Map<String, dynamic> toJson() => {...toMap(), 'id': id};

  factory RoutineItem.fromJson(Map<String, dynamic> j) {
    if (asInt(j['dua_id']) == null && j['dua_key'] == null) {
      throw const FormatException('item without dua_id');
    }
    return RoutineItem.fromMap(j);
  }
}

class Routine {
  const Routine({
    this.id,
    this.key,
    required this.name,
    this.sortOrder = 0,
    this.createdAt = '',
    this.items = const [],
  });

  final int? id;
  final String? key;
  final String name;
  final int sortOrder;
  final String createdAt;
  final List<RoutineItem> items;

  Routine copyWith({
    Object? id = _unset,
    Object? key = _unset,
    String? name,
    int? sortOrder,
    String? createdAt,
    List<RoutineItem>? items,
  }) =>
      Routine(
        id: _pick<int?>(id, this.id),
        key: _pick<String?>(key, this.key),
        name: name ?? this.name,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt ?? this.createdAt,
        items: items ?? this.items,
      );

  /// DB row (items live in routine_items).
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'key': key,
        'name': name,
        'sort_order': sortOrder,
        'created_at': createdAt,
      };

  factory Routine.fromMap(Map<String, Object?> m,
          {List<RoutineItem> items = const []}) =>
      Routine(
        id: asInt(m['id']),
        key: asStringOrNull(m['key']),
        name: asString(m['name']),
        sortOrder: asInt(m['sort_order']) ?? 0,
        createdAt: asString(m['created_at']),
        items: items,
      );

  Map<String, dynamic> toJson() => {
        ...toMap(),
        'id': id,
        'items': [for (final i in items) i.toJson()],
      };

  /// Parses backup JSON. Throws [FormatException] when the name is missing.
  /// Invalid items are dropped (the backup service reports them separately).
  factory Routine.fromJson(Map<String, dynamic> j) {
    final name = asString(j['name']).trim();
    if (name.isEmpty) throw const FormatException('missing routine name');
    final rawItems = j['items'];
    final items = <RoutineItem>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        final m = jsonMap(raw);
        if (m == null) continue;
        try {
          items.add(RoutineItem.fromJson(m));
        } on FormatException {
          continue;
        }
      }
    }
    return Routine.fromMap(j, items: items).copyWith(name: name);
  }
}

// ---------------------------------------------------------------------------
// Reminder
// ---------------------------------------------------------------------------

class Reminder {
  const Reminder({
    this.id,
    this.label = '',
    required this.hour,
    required this.minute,
    this.weekdays = const [1, 2, 3, 4, 5, 6, 7],
    this.routineId,
    this.enabled = true,
    this.snoozeMinutes = 5,
    this.maxSnoozes = 3,
    this.nagEnabled = true,
    this.nagEveryMinutes = 10,
    this.nagMaxTimes = 3,
    this.ringSeconds = 120,
    this.vibrate = true,
    this.sound = 'default',
    this.createdAt = '',
    this.updatedAt = '',
  });

  final int? id;
  final String label;
  final int hour;
  final int minute;

  /// ISO weekdays, Mon=1..Sun=7.
  final List<int> weekdays;
  final int? routineId;
  final bool enabled;
  final int snoozeMinutes;
  final int maxSnoozes;
  final bool nagEnabled;
  final int nagEveryMinutes;
  final int nagMaxTimes;
  final int ringSeconds;
  final bool vibrate;
  final String sound;
  final String createdAt;
  final String updatedAt;

  /// "07:00"
  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  Reminder copyWith({
    Object? id = _unset,
    String? label,
    int? hour,
    int? minute,
    List<int>? weekdays,
    Object? routineId = _unset,
    bool? enabled,
    int? snoozeMinutes,
    int? maxSnoozes,
    bool? nagEnabled,
    int? nagEveryMinutes,
    int? nagMaxTimes,
    int? ringSeconds,
    bool? vibrate,
    String? sound,
    String? createdAt,
    String? updatedAt,
  }) =>
      Reminder(
        id: _pick<int?>(id, this.id),
        label: label ?? this.label,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        weekdays: weekdays ?? this.weekdays,
        routineId: _pick<int?>(routineId, this.routineId),
        enabled: enabled ?? this.enabled,
        snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
        maxSnoozes: maxSnoozes ?? this.maxSnoozes,
        nagEnabled: nagEnabled ?? this.nagEnabled,
        nagEveryMinutes: nagEveryMinutes ?? this.nagEveryMinutes,
        nagMaxTimes: nagMaxTimes ?? this.nagMaxTimes,
        ringSeconds: ringSeconds ?? this.ringSeconds,
        vibrate: vibrate ?? this.vibrate,
        sound: sound ?? this.sound,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'label': label,
        'hour': hour,
        'minute': minute,
        'weekdays': jsonEncode(weekdays),
        'routine_id': routineId,
        'enabled': enabled ? 1 : 0,
        'snooze_minutes': snoozeMinutes,
        'max_snoozes': maxSnoozes,
        'nag_enabled': nagEnabled ? 1 : 0,
        'nag_every_minutes': nagEveryMinutes,
        'nag_max_times': nagMaxTimes,
        'ring_seconds': ringSeconds,
        'vibrate': vibrate ? 1 : 0,
        'sound': sound,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Reminder.fromMap(Map<String, Object?> m) {
    final days = jsonIntList(m['weekdays'])
        .where((d) => d >= 1 && d <= 7)
        .toSet()
        .toList()
      ..sort();
    return Reminder(
      id: asInt(m['id']),
      label: asString(m['label']),
      hour: clampInt(asInt(m['hour']) ?? 0, 0, 23),
      minute: clampInt(asInt(m['minute']) ?? 0, 0, 59),
      weekdays: days,
      routineId: asInt(m['routine_id']),
      enabled: asBool(m['enabled'], fallback: true),
      snoozeMinutes: asInt(m['snooze_minutes']) ?? 5,
      maxSnoozes: asInt(m['max_snoozes']) ?? 3,
      nagEnabled: asBool(m['nag_enabled'], fallback: true),
      nagEveryMinutes: asInt(m['nag_every_minutes']) ?? 10,
      nagMaxTimes: asInt(m['nag_max_times']) ?? 3,
      ringSeconds: asInt(m['ring_seconds']) ?? 120,
      vibrate: asBool(m['vibrate'], fallback: true),
      sound: asString(m['sound'], fallback: 'default'),
      createdAt: asString(m['created_at']),
      updatedAt: asString(m['updated_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        ...toMap(),
        'id': id,
        'weekdays': weekdays,
        'enabled': enabled,
        'nag_enabled': nagEnabled,
        'vibrate': vibrate,
      };

  /// Parses backup JSON. Throws [FormatException] for an invalid time.
  factory Reminder.fromJson(Map<String, dynamic> j) {
    final h = asInt(j['hour']);
    final m = asInt(j['minute']);
    if (h == null || h < 0 || h > 23 || m == null || m < 0 || m > 59) {
      throw const FormatException('invalid reminder time');
    }
    return Reminder.fromMap(j);
  }

  /// Reminder dict for the native alarm engine (ARCHITECTURE.md §7).
  Map<String, dynamic> toNativeJson({required String routineName}) => {
        'id': id,
        'label': label,
        'hour': hour,
        'minute': minute,
        'weekdays': List<int>.of(weekdays),
        'enabled': enabled,
        'routine_id': routineId,
        'routine_name': routineName,
        'snooze_minutes': snoozeMinutes,
        'max_snoozes': maxSnoozes,
        'nag_enabled': nagEnabled,
        'nag_every_minutes': nagEveryMinutes,
        'nag_max_times': nagMaxTimes,
        'ring_seconds': ringSeconds,
        'vibrate': vibrate,
        'sound': sound,
      };
}

// ---------------------------------------------------------------------------
// Session log
// ---------------------------------------------------------------------------

class SessionLog {
  const SessionLog({
    this.id,
    this.routineId,
    required this.startedAt,
    this.finishedAt,
    this.completedDuaIds = const [],
    this.skippedDuaIds = const [],
    this.fromAlarm = false,
    this.reminderId,
    this.completed = false,
    this.stateJson,
  });

  final int? id;
  final int? routineId;
  final String startedAt;
  final String? finishedAt;
  final List<int> completedDuaIds;
  final List<int> skippedDuaIds;
  final bool fromAlarm;
  final int? reminderId;
  final bool completed;

  /// ReciteSession.toJson() while unfinished (resume).
  final String? stateJson;

  SessionLog copyWith({
    Object? id = _unset,
    Object? routineId = _unset,
    String? startedAt,
    Object? finishedAt = _unset,
    List<int>? completedDuaIds,
    List<int>? skippedDuaIds,
    bool? fromAlarm,
    Object? reminderId = _unset,
    bool? completed,
    Object? stateJson = _unset,
  }) =>
      SessionLog(
        id: _pick<int?>(id, this.id),
        routineId: _pick<int?>(routineId, this.routineId),
        startedAt: startedAt ?? this.startedAt,
        finishedAt: _pick<String?>(finishedAt, this.finishedAt),
        completedDuaIds: completedDuaIds ?? this.completedDuaIds,
        skippedDuaIds: skippedDuaIds ?? this.skippedDuaIds,
        fromAlarm: fromAlarm ?? this.fromAlarm,
        reminderId: _pick<int?>(reminderId, this.reminderId),
        completed: completed ?? this.completed,
        stateJson: _pick<String?>(stateJson, this.stateJson),
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'routine_id': routineId,
        'started_at': startedAt,
        'finished_at': finishedAt,
        'completed_dua_ids': jsonEncode(completedDuaIds),
        'skipped_dua_ids': jsonEncode(skippedDuaIds),
        'from_alarm': fromAlarm ? 1 : 0,
        'reminder_id': reminderId,
        'completed': completed ? 1 : 0,
        'state_json': stateJson,
      };

  factory SessionLog.fromMap(Map<String, Object?> m) => SessionLog(
        id: asInt(m['id']),
        routineId: asInt(m['routine_id']),
        startedAt: asString(m['started_at']),
        finishedAt: asStringOrNull(m['finished_at']),
        completedDuaIds: jsonIntList(m['completed_dua_ids']),
        skippedDuaIds: jsonIntList(m['skipped_dua_ids']),
        fromAlarm: asBool(m['from_alarm']),
        reminderId: asInt(m['reminder_id']),
        completed: asBool(m['completed']),
        stateJson: asStringOrNull(m['state_json']),
      );

  Map<String, dynamic> toJson() => {
        ...toMap(),
        'id': id,
        'completed_dua_ids': completedDuaIds,
        'skipped_dua_ids': skippedDuaIds,
        'from_alarm': fromAlarm,
        'completed': completed,
      };

  /// Parses backup JSON. Throws [FormatException] for a bad start time.
  factory SessionLog.fromJson(Map<String, dynamic> j) {
    final started = asString(j['started_at']);
    if (parseIso(started) == null) {
      throw const FormatException('invalid started_at');
    }
    return SessionLog.fromMap(j);
  }
}

// ---------------------------------------------------------------------------
// Alarm event
// ---------------------------------------------------------------------------

/// event ∈ rang, auto_stopped, snoozed, dismissed, started, nag_rang, test_rang
class AlarmEvent {
  const AlarmEvent({
    this.id,
    required this.reminderId,
    required this.occurrenceMs,
    required this.event,
    required this.atMs,
    this.label = '',
  });

  final int? id;
  final int reminderId;
  final int occurrenceMs;
  final String event;
  final int atMs;
  final String label;

  AlarmEvent copyWith({
    Object? id = _unset,
    int? reminderId,
    int? occurrenceMs,
    String? event,
    int? atMs,
    String? label,
  }) =>
      AlarmEvent(
        id: _pick<int?>(id, this.id),
        reminderId: reminderId ?? this.reminderId,
        occurrenceMs: occurrenceMs ?? this.occurrenceMs,
        event: event ?? this.event,
        atMs: atMs ?? this.atMs,
        label: label ?? this.label,
      );

  /// DB row; keys match the native event dict (§7) plus `id`.
  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'reminder_id': reminderId,
        'occurrence_ms': occurrenceMs,
        'event': event,
        'at_ms': atMs,
        'label': label,
      };

  /// Accepts DB rows and native event dicts (snake_case keys).
  factory AlarmEvent.fromMap(Map<String, Object?> m) => AlarmEvent(
        id: asInt(m['id']),
        reminderId: asInt(m['reminder_id']) ?? 0,
        occurrenceMs: asInt(m['occurrence_ms']) ?? 0,
        event: asString(m['event']),
        atMs: asInt(m['at_ms']) ?? 0,
        label: asString(m['label']),
      );

  Map<String, dynamic> toJson() => {...toMap(), 'id': id};

  factory AlarmEvent.fromJson(Map<String, dynamic> j) => AlarmEvent.fromMap(j);
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

class ChatMessage {
  const ChatMessage({
    this.id,
    required this.role,
    required this.text,
    this.payloadJson,
    this.createdAt = '',
  });

  final int? id;

  /// user | assistant | error
  final String role;
  final String text;
  final String? payloadJson;
  final String createdAt;

  bool get isUser => role == 'user';

  ChatMessage copyWith({
    Object? id = _unset,
    String? role,
    String? text,
    Object? payloadJson = _unset,
    String? createdAt,
  }) =>
      ChatMessage(
        id: _pick<int?>(id, this.id),
        role: role ?? this.role,
        text: text ?? this.text,
        payloadJson: _pick<String?>(payloadJson, this.payloadJson),
        createdAt: createdAt ?? this.createdAt,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'role': role,
        'text': text,
        'payload_json': payloadJson,
        'created_at': createdAt,
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: asInt(m['id']),
        role: asString(m['role'], fallback: 'user'),
        text: asString(m['text']),
        payloadJson: asStringOrNull(m['payload_json']),
        createdAt: asString(m['created_at']),
      );

  Map<String, dynamic> toJson() => {...toMap(), 'id': id};

  factory ChatMessage.fromJson(Map<String, dynamic> j) =>
      ChatMessage.fromMap(j);
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.arabicFontSize = 30,
    this.showTransliteration = true,
    this.showTranslation = true,
    this.haptics = true,
    this.counterMode = CounterMode.countUp,
    this.autoAdvance = true,
    this.audioMode = AudioMode.off,
    this.playbackRate = 1.0,
    this.reciter = 'Alafasy_128kbps',
    this.llmProvider = 'gemini',
    this.geminiApiKey = '',
    this.geminiModel = 'gemini-flash-latest',
    this.anthropicApiKey = '',
    this.anthropicModel = 'claude-sonnet-5-5',
    this.translationLanguage = 'Urdu',
    this.defaultSnoozeMinutes = 5,
    this.defaultRoutineId,
    this.onboardingDone = false,
  });

  final ThemeMode themeMode;

  /// 20..56
  final int arabicFontSize;
  final bool showTransliteration;
  final bool showTranslation;
  final bool haptics;
  final CounterMode counterMode;
  final bool autoAdvance;
  final AudioMode audioMode;

  /// 0.75..1.25
  final double playbackRate;
  final String reciter;

  /// gemini | anthropic
  final String llmProvider;

  /// '' => [defaultGeminiApiKey]
  final String geminiApiKey;
  final String geminiModel;
  final String anthropicApiKey;
  final String anthropicModel;
  final String translationLanguage;
  final int defaultSnoozeMinutes;
  final int? defaultRoutineId;
  final bool onboardingDone;

  /// JSON keys holding secrets; never exported in backups.
  static const secretKeys = {'geminiApiKey', 'anthropicApiKey'};

  String get effectiveGeminiKey {
    final k = geminiApiKey.trim();
    return k.isEmpty ? defaultGeminiApiKey : k;
  }

  /// True when the user entered their own Gemini key.
  bool get hasOwnGeminiKey => geminiApiKey.trim().isNotEmpty;

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? arabicFontSize,
    bool? showTransliteration,
    bool? showTranslation,
    bool? haptics,
    CounterMode? counterMode,
    bool? autoAdvance,
    AudioMode? audioMode,
    double? playbackRate,
    String? reciter,
    String? llmProvider,
    String? geminiApiKey,
    String? geminiModel,
    String? anthropicApiKey,
    String? anthropicModel,
    String? translationLanguage,
    int? defaultSnoozeMinutes,
    Object? defaultRoutineId = _unset,
    bool? onboardingDone,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        arabicFontSize: arabicFontSize ?? this.arabicFontSize,
        showTransliteration: showTransliteration ?? this.showTransliteration,
        showTranslation: showTranslation ?? this.showTranslation,
        haptics: haptics ?? this.haptics,
        counterMode: counterMode ?? this.counterMode,
        autoAdvance: autoAdvance ?? this.autoAdvance,
        audioMode: audioMode ?? this.audioMode,
        playbackRate: playbackRate ?? this.playbackRate,
        reciter: reciter ?? this.reciter,
        llmProvider: llmProvider ?? this.llmProvider,
        geminiApiKey: geminiApiKey ?? this.geminiApiKey,
        geminiModel: geminiModel ?? this.geminiModel,
        anthropicApiKey: anthropicApiKey ?? this.anthropicApiKey,
        anthropicModel: anthropicModel ?? this.anthropicModel,
        translationLanguage: translationLanguage ?? this.translationLanguage,
        defaultSnoozeMinutes: defaultSnoozeMinutes ?? this.defaultSnoozeMinutes,
        defaultRoutineId: _pick<int?>(defaultRoutineId, this.defaultRoutineId),
        onboardingDone: onboardingDone ?? this.onboardingDone,
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'arabicFontSize': arabicFontSize,
        'showTransliteration': showTransliteration,
        'showTranslation': showTranslation,
        'haptics': haptics,
        'counterMode': counterMode.name,
        'autoAdvance': autoAdvance,
        'audioMode': audioMode.name,
        'playbackRate': playbackRate,
        'reciter': reciter,
        'llmProvider': llmProvider,
        'geminiApiKey': geminiApiKey,
        'geminiModel': geminiModel,
        'anthropicApiKey': anthropicApiKey,
        'anthropicModel': anthropicModel,
        'translationLanguage': translationLanguage,
        'defaultSnoozeMinutes': defaultSnoozeMinutes,
        'defaultRoutineId': defaultRoutineId,
        'onboardingDone': onboardingDone,
      };

  /// Lenient: unknown/invalid values fall back to defaults; numbers clamped.
  factory AppSettings.fromJson(Map<String, dynamic> j) {
    const d = AppSettings();
    String str(String k, String fallback) {
      final v = j[k];
      return v is String ? v : fallback;
    }

    final provider = str('llmProvider', d.llmProvider);
    final rate = asDouble(j['playbackRate']) ?? d.playbackRate;
    return AppSettings(
      themeMode: _enumByName(ThemeMode.values, j['themeMode'], d.themeMode),
      arabicFontSize: clampInt(asInt(j['arabicFontSize']) ?? d.arabicFontSize,
          minArabicFontSize, maxArabicFontSize),
      showTransliteration:
          asBool(j['showTransliteration'], fallback: d.showTransliteration),
      showTranslation: asBool(j['showTranslation'], fallback: d.showTranslation),
      haptics: asBool(j['haptics'], fallback: d.haptics),
      counterMode:
          _enumByName(CounterMode.values, j['counterMode'], d.counterMode),
      autoAdvance: asBool(j['autoAdvance'], fallback: d.autoAdvance),
      audioMode: _enumByName(AudioMode.values, j['audioMode'], d.audioMode),
      playbackRate: rate < 0.75 ? 0.75 : (rate > 1.25 ? 1.25 : rate),
      reciter: str('reciter', d.reciter),
      llmProvider:
          (provider == 'gemini' || provider == 'anthropic') ? provider : 'gemini',
      geminiApiKey: str('geminiApiKey', d.geminiApiKey),
      geminiModel: str('geminiModel', d.geminiModel),
      anthropicApiKey: str('anthropicApiKey', d.anthropicApiKey),
      anthropicModel: str('anthropicModel', d.anthropicModel),
      translationLanguage: str('translationLanguage', d.translationLanguage),
      defaultSnoozeMinutes: clampInt(
          asInt(j['defaultSnoozeMinutes']) ?? d.defaultSnoozeMinutes, 1, 60),
      defaultRoutineId: asInt(j['defaultRoutineId']),
      onboardingDone: asBool(j['onboardingDone'], fallback: d.onboardingDone),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      const _MapEq().equals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);

  @override
  String toString() {
    // Never include API keys.
    final j = toJson()..removeWhere((k, _) => secretKeys.contains(k));
    return 'AppSettings($j)';
  }
}

class _MapEq {
  const _MapEq();
  bool equals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
    }
    return true;
  }
}
