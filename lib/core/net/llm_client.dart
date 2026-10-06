/// Chat-based dua suggestions and meaning translation through Gemini or
/// Anthropic. API keys are sent only in request headers and never appear in
/// exception text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, HttpException, SocketException;

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// One dua proposed by the assistant.
class DuaSuggestion {
  const DuaSuggestion({
    required this.title,
    required this.arabic,
    this.transliteration = '',
    this.translation = '',
    this.source = '',
    this.category = 'General',
    this.repeat = 1,
    this.kind = 'hadith',
    this.quran,
  });

  final String title;
  final String arabic;
  final String transliteration;
  final String translation;
  final String source;
  final String category;

  /// 1..100
  final int repeat;

  /// 'quran' | 'hadith'
  final String kind;

  /// `{surah, ayah_start, ayah_end}` for Quran duas, else null.
  final Map<String, dynamic>? quran;

  bool get isQuran => kind == 'quran';

  Map<String, dynamic> toJson() => {
        'title': title,
        'arabic': arabic,
        'transliteration': transliteration,
        'translation': translation,
        'source': source,
        'category': category,
        'repeat': repeat,
        'kind': kind,
        'quran': quran,
      };

  /// Lenient parse; returns null when title or Arabic is missing.
  static DuaSuggestion? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    String str(String k) => (m[k] is String) ? (m[k] as String).trim() : '';
    final arabic = str('arabic');
    var title = str('title');
    if (arabic.isEmpty) return null;
    if (title.isEmpty) title = 'Dua';
    final quran = _parseQuranRef(m['quran']);
    final kindRaw = str('kind').toLowerCase();
    final kind = (kindRaw == 'quran' || (kindRaw.isEmpty && quran != null))
        ? 'quran'
        : 'hadith';
    final category = str('category');
    return DuaSuggestion(
      title: title,
      arabic: arabic,
      transliteration: str('transliteration'),
      translation: str('translation'),
      source: str('source'),
      category: category.isEmpty ? 'General' : category,
      repeat: (_asInt(m['repeat']) ?? 1).clamp(1, 100),
      kind: kind,
      quran: kind == 'quran' ? quran : null,
    );
  }

  factory DuaSuggestion.fromJson(Map<String, dynamic> m) =>
      tryParse(m) ?? (throw const FormatException('Invalid dua suggestion'));
}

class ChatReply {
  const ChatReply({required this.reply, this.duas = const []});

  final String reply;
  final List<DuaSuggestion> duas;

  Map<String, dynamic> toJson() => {
        'reply': reply,
        'duas': [for (final d in duas) d.toJson()],
      };

  factory ChatReply.fromJson(Map<String, dynamic> m) => parseReply(jsonEncode(m));
}

class LlmException implements Exception {
  const LlmException(this.kind, this.userMessage, {this.details = ''});

  /// offline | bad_key | denied | rate_limit | server | bad_json | no_key | timeout
  final String kind;

  /// Friendly text to show in the UI (never contains the API key).
  final String userMessage;

  /// Technical details for debugging: provider, model, HTTP status, the
  /// provider's own error message, which key was used (masked) and the
  /// attempts made. Never contains the full API key.
  final String details;

  /// [userMessage] followed by [details], for showing the exact error.
  String get fullMessage =>
      details.isEmpty ? userMessage : '$userMessage\n\nDetails:\n$details';

  LlmException withDetails(String extra) => LlmException(kind, userMessage,
      details: [extra, details].where((s) => s.isNotEmpty).join('\n'));

  @override
  String toString() => 'LlmException($kind): $userMessage';
}

const String _anthropic = 'anthropic';
const int maxSuggestedDuas = 3;
const int _historyLimit = 10;

/// System prompt for dua suggestions.
const String duaSystemPrompt = '''
You are a gentle, knowledgeable assistant inside "Daily Duas", an app that helps a Muslim find and recite duas (supplications).

When the user describes a need, feeling or situation, suggest up to 3 fitting duas.

STRICT RULES ABOUT AUTHENTICITY
- Only suggest duas that come from the Quran or from authentic hadith (graded sahih or hasan). Never suggest weak or fabricated narrations.
- Every dua must have a precise source, e.g. "Quran 2:201", "Quran 3:8", "Sahih al-Bukhari 6306", "Sahih Muslim 2720", "Sunan Abi Dawud 5090".
- The Arabic must be the exact wording of the source, written in standard (imla'i) Arabic script with full tashkeel. Do not paraphrase, shorten or merge texts. For Quran duas give the exact ayah text and fill "quran" with the surah and ayah range; do not include the Bismillah unless it is part of the ayah.
- If you are not certain of the exact wording or the source, do NOT guess: return an empty "duas" list and say so kindly in "reply" (you may suggest asking a scholar).
- Never invent hadith numbers, wording or virtues.
- Do not give fatwas or rulings; for religious rulings advise consulting a qualified scholar.

STYLE
- "reply" is short (1-3 sentences), warm and encouraging, in the user's language.
- "transliteration" is an easy Latin transliteration; "translation" is a faithful English meaning.
- "category" is one word or two, e.g. Protection, Anxiety, Forgiveness, Gratitude, Travel, Sleep, Morning, Evening, Evil eye, Acceptance, General.
- "repeat" is how many times to recite it (1-100), following the sunnah when a number is narrated, otherwise 1 or 3.
- "kind" is "quran" or "hadith". For hadith duas "quran" is null.

OUTPUT
Reply with JSON ONLY, no markdown, no code fences, exactly this shape:
{"reply": "short warm text", "duas": [{"title": "...", "arabic": "...", "transliteration": "...", "translation": "...", "source": "...", "category": "...", "repeat": 1, "kind": "quran", "quran": {"surah": 2, "ayah_start": 201, "ayah_end": 201}}]}
''';

String translationSystemPrompt(String language) => '''
You translate Islamic supplications (duas) and their meanings.
Translate the meaning of the user's text faithfully into $language.
Output only the translation as plain text: no commentary, no notes, no transliteration, no quotation marks, no markdown.
Keep the names of Allah and of the Prophets respectful and conventional in $language.''';

/// Gemini responseSchema (OpenAPI subset) for [duaSystemPrompt].
const Map<String, dynamic> _geminiSchema = {
  'type': 'OBJECT',
  'properties': {
    'reply': {'type': 'STRING'},
    'duas': {
      'type': 'ARRAY',
      'items': {
        'type': 'OBJECT',
        'properties': {
          'title': {'type': 'STRING'},
          'arabic': {'type': 'STRING'},
          'transliteration': {'type': 'STRING'},
          'translation': {'type': 'STRING'},
          'source': {'type': 'STRING'},
          'category': {'type': 'STRING'},
          'repeat': {'type': 'INTEGER'},
          'kind': {'type': 'STRING'},
          'quran': {
            'type': 'OBJECT',
            'nullable': true,
            'properties': {
              'surah': {'type': 'INTEGER'},
              'ayah_start': {'type': 'INTEGER'},
              'ayah_end': {'type': 'INTEGER'},
            },
            'required': ['surah', 'ayah_start', 'ayah_end'],
          },
        },
        'required': [
          'title',
          'arabic',
          'transliteration',
          'translation',
          'source',
          'category',
          'repeat',
          'kind',
        ],
        'propertyOrdering': [
          'title',
          'arabic',
          'transliteration',
          'translation',
          'source',
          'category',
          'repeat',
          'kind',
          'quran',
        ],
      },
    },
  },
  'required': ['reply', 'duas'],
  'propertyOrdering': ['reply', 'duas'],
};

class LlmClient {
  LlmClient({
    required this._settings,
    http.Client? client,
    this.timeout = const Duration(seconds: 60),
    this.retryDelay = const Duration(milliseconds: 1500),
  }) : _client = client ?? http.Client();

  final AppSettings Function() _settings;
  final http.Client _client;
  final Duration timeout;

  /// Pause before retrying a Gemini call that failed with a transient status.
  final Duration retryDelay;

  static const _geminiFallbackModel = 'gemini-flash-lite-latest';
  static const _transientStatus = {429, 500, 502, 503, 504};

  /// Asks the configured provider for duas matching [userText].
  /// [history] is the stored chat; the last 10 user/assistant messages are
  /// sent as context.
  Future<ChatReply> suggestDuas(String userText, List<ChatMessage> history) async {
    final turns = _buildTurns(userText, history);
    final raw = await _complete(system: duaSystemPrompt, turns: turns, json: true);
    return parseReply(raw);
  }

  /// Plain-text meaning translation of [text] into [targetLanguage].
  Future<String> translate(String text, String targetLanguage) async {
    final raw = await _complete(
      system: translationSystemPrompt(targetLanguage),
      turns: [('user', text)],
      json: false,
    );
    final cleaned = _cleanPlainText(raw);
    if (cleaned.isEmpty) {
      throw const LlmException(
          'bad_json', 'The translation came back empty. Please try again.');
    }
    return cleaned;
  }

  /// Sends a tiny request to check the key and model. Returns a short status
  /// line, throws [LlmException] on failure.
  Future<String> testConnection() async {
    final s = _settings();
    await _complete(
      system: 'Reply with the single word OK.',
      turns: [('user', 'Test')],
      json: false,
      maxTokens: 1024,
    );
    return s.llmProvider == _anthropic
        ? 'Connected to Anthropic (${s.anthropicModel}).'
        : 'Connected to Google Gemini (${s.geminiModel}).';
  }

  void close() => _client.close();

  // -------------------------------------------------------------------------

  List<(String, String)> _buildTurns(String userText, List<ChatMessage> history) {
    final relevant = history
        .where((m) => (m.role == 'user' || m.role == 'assistant') && m.text.trim().isNotEmpty)
        .toList();
    // The caller may already have stored the current message.
    if (relevant.isNotEmpty &&
        relevant.last.role == 'user' &&
        relevant.last.text.trim() == userText.trim()) {
      relevant.removeLast();
    }
    final recent = relevant.length > _historyLimit
        ? relevant.sublist(relevant.length - _historyLimit)
        : relevant;
    final turns = <(String, String)>[];
    for (final m in recent) {
      final content = m.role == 'assistant' &&
              m.payloadJson != null &&
              m.payloadJson!.trim().isNotEmpty
          ? m.payloadJson!
          : m.text;
      _appendTurn(turns, m.role, content);
    }
    _appendTurn(turns, 'user', userText);
    // Both APIs expect the conversation to start with the user.
    while (turns.isNotEmpty && turns.first.$1 != 'user') {
      turns.removeAt(0);
    }
    return turns;
  }

  static void _appendTurn(List<(String, String)> turns, String role, String text) {
    if (turns.isNotEmpty && turns.last.$1 == role) {
      final prev = turns.removeLast();
      turns.add((role, '${prev.$2}\n\n$text'));
    } else {
      turns.add((role, text));
    }
  }

  Future<String> _complete({
    required String system,
    required List<(String, String)> turns,
    required bool json,
    int? maxTokens,
  }) async {
    final s = _settings();
    if (s.llmProvider == _anthropic) {
      final key = s.anthropicApiKey.trim();
      if (key.isEmpty) {
        throw const LlmException('no_key',
            'Add your Anthropic API key in Settings to use the assistant.');
      }
      try {
        return await _anthropicCall(s, key, system, turns, maxTokens: maxTokens);
      } on LlmException catch (e) {
        throw e.withDetails('Provider: Anthropic\nModel: ${s.anthropicModel}\nKey: ${_keyHint(key)}');
      }
    }
    final key = s.effectiveGeminiKey.trim();
    if (key.isEmpty) {
      throw const LlmException(
          'no_key', 'Add a Gemini API key in Settings to use the assistant.');
    }
    try {
      return await _geminiCall(s, key, system, turns, json: json);
    } on LlmException catch (e) {
      final source = s.geminiApiKey.trim().isEmpty ? 'built-in' : 'entered in Settings';
      throw e.withDetails(
          'Provider: Google Gemini\nModel: ${s.geminiModel}\nKey: ${_keyHint(key)} ($source)');
    }
  }

  /// First 6 and last 4 characters of a key, enough to tell keys apart.
  static String _keyHint(String key) => key.length <= 12
      ? '***'
      : '${key.substring(0, 6)}…${key.substring(key.length - 4)}';

  Future<String> _geminiCall(
    AppSettings s,
    String key,
    String system,
    List<(String, String)> turns, {
    required bool json,
  }) async {
    final primary = s.geminiModel.trim().isEmpty ? 'gemini-flash-latest' : s.geminiModel.trim();
    final body = {
      'systemInstruction': {
        'parts': [
          {'text': system},
        ],
      },
      'contents': [
        for (final (role, text) in turns)
          {
            'role': role == 'assistant' ? 'model' : 'user',
            'parts': [
              {'text': text},
            ],
          },
      ],
      'generationConfig': {
        'temperature': 0.2,
        if (json) 'responseMimeType': 'application/json',
        if (json) 'responseSchema': _geminiSchema,
      },
    };
    // Gemini often answers 503 "high demand" (or 429/5xx) for a few seconds:
    // retry the chosen model once, then fall back to the lighter model.
    final attempts = [
      primary,
      primary,
      if (primary != _geminiFallbackModel) _geminiFallbackModel,
    ];
    late http.Response res;
    var model = primary;
    final tried = <String>[];
    for (var i = 0; i < attempts.length; i++) {
      if (i > 0) await Future<void>.delayed(retryDelay);
      model = attempts[i];
      final uri = Uri.https('generativelanguage.googleapis.com',
          '/v1beta/models/${Uri.encodeComponent(model)}:generateContent');
      res = await _post(uri, {
        'Content-Type': 'application/json; charset=utf-8',
        'x-goog-api-key': key,
      }, body, key);
      tried.add('$model → HTTP ${res.statusCode}');
      if (!_transientStatus.contains(res.statusCode)) break;
    }
    if (res.statusCode != 200) {
      throw _geminiError(res, key, model).withDetails('Attempts: ${tried.join(', ')}');
    }
    final decoded = _decodeBody(res);
    final blockReason = (decoded['promptFeedback'] as Map?)?['blockReason'];
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      if (blockReason != null) {
        throw LlmException('server',
            'The AI declined this request (safety filter). Try rephrasing it.',
            details: 'Model: $model\nblockReason: $blockReason');
      }
      throw LlmException('bad_json', 'The AI sent an empty answer. Please try again.',
          details: 'Model: $model\nNo candidates. Body: ${_snippet(res, key)}');
    }
    final first = candidates.first as Map;
    final parts = (first['content'] as Map?)?['parts'];
    final text = StringBuffer();
    if (parts is List) {
      for (final p in parts) {
        if (p is Map && p['thought'] != true && p['text'] is String) {
          text.write(p['text']);
        }
      }
    }
    if (text.isEmpty) {
      final reason = first['finishReason'];
      if (reason == 'SAFETY' || reason == 'PROHIBITED_CONTENT' || reason == 'BLOCKLIST') {
        throw LlmException('server',
            'The AI declined this request (safety filter). Try rephrasing it.',
            details: 'Model: $model\nfinishReason: $reason');
      }
      throw LlmException('bad_json', 'The AI sent an empty answer. Please try again.',
          details: 'Model: $model\nfinishReason: $reason\nBody: ${_snippet(res, key)}');
    }
    return text.toString();
  }

  Future<String> _anthropicCall(
    AppSettings s,
    String key,
    String system,
    List<(String, String)> turns, {
    int? maxTokens,
  }) async {
    final model = s.anthropicModel.trim().isEmpty ? 'claude-sonnet-5-5' : s.anthropicModel.trim();
    final useFallbacks = _supportsServerFallback(model);
    final body = {
      'model': model,
      'max_tokens': maxTokens ?? 16000,
      'system': system,
      'messages': [
        for (final (role, text) in turns)
          {'role': role == 'assistant' ? 'assistant' : 'user', 'content': text},
      ],
      if (useFallbacks) 'fallbacks': 'default',
    };
    final res = await _post(
      Uri.https('api.anthropic.com', '/v1/messages'),
      {
        'Content-Type': 'application/json; charset=utf-8',
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        if (useFallbacks) 'anthropic-beta': 'server-side-fallback-2026-07-01',
      },
      body,
      key,
    );
    if (res.statusCode != 200) {
      throw _anthropicError(res, key, model);
    }
    final decoded = _decodeBody(res);
    if (decoded['stop_reason'] == 'refusal') {
      throw const LlmException('server',
          'The AI declined this request (safety filter). Try rephrasing it.');
    }
    final content = decoded['content'];
    final text = StringBuffer();
    if (content is List) {
      for (final b in content) {
        if (b is Map && b['type'] == 'text' && b['text'] is String) {
          text.write(b['text']);
        }
      }
    }
    if (text.isEmpty) {
      throw const LlmException('bad_json', 'The AI sent an empty answer. Please try again.');
    }
    return text.toString();
  }

  /// Server-side refusal fallback is offered for the Claude 5.x generation.
  static bool _supportsServerFallback(String model) =>
      model.startsWith('claude-sonnet-5-5') ||
      model.startsWith('claude-opus-5') ||
      model.startsWith('claude-fable-5');

  Future<http.Response> _post(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
    String key,
  ) async {
    try {
      return await _client
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(timeout);
    } on TimeoutException {
      throw LlmException(
          'timeout', 'The AI took too long to answer. Check your connection and try again.',
          details: 'No response from ${uri.host} within ${timeout.inSeconds} s');
    } on SocketException catch (e) {
      throw _offline.withDetails('SocketException: ${_redact(e.toString(), key)}');
    } on HandshakeException catch (e) {
      throw _offline.withDetails('HandshakeException (TLS): ${_redact(e.toString(), key)}');
    } on HttpException catch (e) {
      throw _offline.withDetails('HttpException: ${_redact(e.toString(), key)}');
    } on http.ClientException catch (e) {
      final msg = _redact(e.message, key);
      if (msg.toLowerCase().contains('timed out')) {
        throw LlmException(
            'timeout', 'The AI took too long to answer. Check your connection and try again.',
            details: 'ClientException: $msg');
      }
      throw _offline.withDetails('ClientException: $msg');
    }
  }

  static const LlmException _offline = LlmException(
      'offline', "Can't reach the AI service. Check your internet connection and try again.");

  static Map<String, dynamic> _decodeBody(http.Response res) {
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map<String, dynamic>) return d;
    } on FormatException {
      // fall through
    }
    throw LlmException('bad_json', "The AI service sent a response the app couldn't read.",
        details: 'HTTP ${res.statusCode}, body: ${_snippet(res, '')}');
  }

  /// First 300 characters of the response body, with the key masked.
  static String _snippet(http.Response res, String key) {
    final text = _redact(utf8.decode(res.bodyBytes, allowMalformed: true), key)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }

  /// HTTP status plus the provider's own error status, reason and message.
  static String _httpDetails(http.Response res, String key) {
    final info = _errorInfo(res, key);
    return [
      'HTTP ${res.statusCode}${info.status.isEmpty ? '' : ' ${info.status}'}',
      if (info.reason.isNotEmpty) 'Reason: ${info.reason}',
      if (info.message.isNotEmpty) 'Message: ${info.message}' else 'Body: ${_snippet(res, key)}',
    ].join('\n');
  }

  static ({String status, String message, String reason}) _errorInfo(
      http.Response res, String key) {
    var status = '', message = '', reason = '';
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map && d['error'] is Map) {
        final e = d['error'] as Map;
        status = '${e['status'] ?? e['type'] ?? ''}';
        message = '${e['message'] ?? ''}';
        final details = e['details'];
        if (details is List) {
          for (final x in details) {
            if (x is Map && x['reason'] is String) reason = x['reason'] as String;
          }
        }
      }
    } on FormatException {
      // non-JSON error body
    }
    message = _redact(message, key);
    if (message.length > 600) message = '${message.substring(0, 600)}…';
    return (status: status, message: message, reason: reason);
  }

  static LlmException _geminiError(http.Response res, String key, String model) =>
      _geminiErrorBase(res, key, model).withDetails(_httpDetails(res, key));

  static LlmException _geminiErrorBase(http.Response res, String key, String model) {
    final info = _errorInfo(res, key);
    final code = res.statusCode;
    final keyProblem = info.reason == 'API_KEY_INVALID' ||
        info.reason == 'API_KEY_EXPIRED' ||
        info.message.toLowerCase().contains('api key not valid') ||
        info.message.toLowerCase().contains('api key expired');
    if (code == 401 || (code == 400 && keyProblem)) {
      return const LlmException('bad_key',
          'Google rejected the API key. Check the Gemini key in Settings.');
    }
    if (code == 403) {
      return const LlmException('denied',
          'Google refused this key/project (403). Check the key in Settings or your Google AI Studio project.');
    }
    if (code == 429) {
      return const LlmException('rate_limit',
          'Too many requests or the free quota is used up. Please wait a minute and try again.');
    }
    if (code == 404) {
      return LlmException('server',
          'The model "$model" was not found. Choose another Gemini model in Settings.');
    }
    if (code >= 500) {
      return LlmException('server',
          'The Gemini service is having trouble ($code). Please try again later.');
    }
    return LlmException('server',
        'The Gemini service returned an error ($code)${info.message.isEmpty ? '' : ': ${info.message}'}');
  }

  static LlmException _anthropicError(http.Response res, String key, String model) =>
      _anthropicErrorBase(res, key, model).withDetails(_httpDetails(res, key));

  static LlmException _anthropicErrorBase(http.Response res, String key, String model) {
    final info = _errorInfo(res, key);
    final code = res.statusCode;
    if (code == 401 || info.status == 'authentication_error') {
      return const LlmException('bad_key',
          'Anthropic rejected the API key. Check the Anthropic key in Settings.');
    }
    if (code == 403 || info.status == 'permission_error') {
      return const LlmException('denied',
          'Anthropic refused this key (403). Check the key and your Anthropic Console account.');
    }
    if (code == 429) {
      return const LlmException('rate_limit',
          'Too many requests to Anthropic. Please wait a minute and try again.');
    }
    if (code == 404) {
      return LlmException('server',
          'The model "$model" was not found. Choose another Anthropic model in Settings.');
    }
    if (code >= 500) {
      return LlmException('server',
          'The Anthropic service is busy or having trouble ($code). Please try again later.');
    }
    return LlmException('server',
        'The Anthropic service returned an error ($code)${info.message.isEmpty ? '' : ': ${info.message}'}');
  }

  static String _redact(String text, String key) {
    if (key.isEmpty) return text;
    return text.replaceAll(key, '***');
  }

  static String _cleanPlainText(String raw) {
    var t = raw.trim();
    final fence = RegExp(r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$').firstMatch(t);
    if (fence != null) t = fence[1]!.trim();
    if (t.length >= 2) {
      const pairs = {'"': '"', '“': '”', '«': '»', "'": "'"};
      final close = pairs[t[0]];
      if (close != null && t.endsWith(close)) t = t.substring(1, t.length - 1).trim();
    }
    return t;
  }
}

/// Parses the assistant's JSON answer. Tolerates ```json fences and text
/// around the JSON object. Throws [LlmException] `bad_json` when no JSON can
/// be read. At most [maxSuggestedDuas] duas are returned; entries without
/// Arabic are dropped.
ChatReply parseReply(String raw) {
  const badJson = LlmException(
      'bad_json', "The assistant's answer couldn't be read. Please try again.");
  var t = raw.trim();
  final fence = RegExp(r'```(?:json|JSON)?\s*([\s\S]*?)```').firstMatch(t);
  if (fence != null) t = fence[1]!.trim();
  Object? decoded;
  try {
    decoded = jsonDecode(t);
  } on FormatException {
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) throw badJson;
    try {
      decoded = jsonDecode(t.substring(start, end + 1));
    } on FormatException {
      throw badJson;
    }
  }
  String reply;
  Object? duasRaw;
  if (decoded is Map) {
    final r = decoded['reply'] ?? decoded['message'] ?? decoded['text'];
    reply = r is String ? r.trim() : '';
    duasRaw = decoded['duas'];
  } else if (decoded is List) {
    reply = '';
    duasRaw = decoded;
  } else {
    throw badJson;
  }
  final duas = <DuaSuggestion>[];
  if (duasRaw is List) {
    for (final d in duasRaw) {
      final s = DuaSuggestion.tryParse(d);
      if (s != null) duas.add(s);
      if (duas.length >= maxSuggestedDuas) break;
    }
  }
  if (reply.isEmpty && duas.isEmpty) {
    reply = "I couldn't find a dua I'm certain about for this. "
        'Please ask a knowledgeable teacher or scholar.';
  }
  return ChatReply(reply: reply, duas: List.unmodifiable(duas));
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

Map<String, dynamic>? _parseQuranRef(Object? raw) {
  if (raw is! Map) return null;
  final s = _asInt(raw['surah']);
  final a = _asInt(raw['ayah_start'] ?? raw['ayahStart'] ?? raw['ayah']);
  if (s == null || a == null || s < 1 || s > 114 || a < 1) return null;
  var e = _asInt(raw['ayah_end'] ?? raw['ayahEnd']) ?? a;
  if (e < a) e = a;
  return {'surah': s, 'ayah_start': a, 'ayah_end': e};
}
