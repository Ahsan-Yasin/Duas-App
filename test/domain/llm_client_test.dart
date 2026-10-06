import 'dart:convert';

import 'package:daily_duas/core/models/models.dart';
import 'package:daily_duas/core/net/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _key = 'TEST-KEY-abc123';

const _duaJson = {
  'reply': 'Here is a beautiful dua for this life and the next.',
  'duas': [
    {
      'title': 'Good in this world and the next',
      'arabic': 'رَبَّنَا آتِنَا فِي الدُّنْيَا حَسَنَةً وَفِي الْآخِرَةِ حَسَنَةً وَقِنَا عَذَابَ النَّارِ',
      'transliteration': 'Rabbana atina fid-dunya hasanah...',
      'translation': 'Our Lord, give us good in this world...',
      'source': 'Quran 2:201',
      'category': 'General',
      'repeat': 3,
      'kind': 'quran',
      'quran': {'surah': 2, 'ayah_start': 201, 'ayah_end': 201},
    },
  ],
};

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _geminiOk(String text) => {
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': [
              {'text': text},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    };

LlmClient _client(http.Client mock, {AppSettings? settings, Duration? timeout}) => LlmClient(
      settings: () => settings ?? const AppSettings(geminiApiKey: _key),
      client: mock,
      timeout: timeout ?? const Duration(seconds: 60),
      retryDelay: Duration.zero,
    );

Future<LlmException> _expectLlmError(Future<Object?> f) async {
  try {
    await f;
  } on LlmException catch (e) {
    expect(e.userMessage, isNot(contains(_key)));
    expect(e.toString(), isNot(contains(_key)));
    return e;
  }
  fail('expected LlmException');
}

void main() {
  group('Gemini', () {
    test('success: request shape and parsed reply', () async {
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        return _json(_geminiOk(jsonEncode(_duaJson)));
      });
      final history = [
        for (var i = 0; i < 14; i++)
          ChatMessage(role: i.isEven ? 'user' : 'assistant', text: 'message $i'),
        const ChatMessage(role: 'error', text: 'boom'),
      ];
      final reply = await _client(mock).suggestDuas('I need a dua for goodness', history);

      expect(captured.method, 'POST');
      expect(captured.url.host, 'generativelanguage.googleapis.com');
      expect(captured.url.path, '/v1beta/models/gemini-flash-latest:generateContent');
      expect(captured.url.query, isEmpty); // key only in the header
      expect(captured.headers['x-goog-api-key'], _key);
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config['responseMimeType'], 'application/json');
      expect(config['temperature'], 0.2);
      expect(config['responseSchema'], isA<Map<String, dynamic>>());
      expect(
        (body['systemInstruction']['parts'] as List).first['text'],
        contains('JSON ONLY'),
      );
      final contents = body['contents'] as List;
      // 10 history messages (+ current) – roles alternate and start with user.
      expect(contents.first['role'], 'user');
      expect(contents.last['parts'][0]['text'], 'I need a dua for goodness');
      expect(contents.where((c) => (c['parts'][0]['text'] as String).contains('message')).length,
          lessThanOrEqualTo(10));
      expect(jsonEncode(contents), isNot(contains('boom')));

      expect(reply.reply, startsWith('Here is'));
      expect(reply.duas, hasLength(1));
      final d = reply.duas.single;
      expect(d.kind, 'quran');
      expect(d.repeat, 3);
      expect(d.quran, {'surah': 2, 'ayah_start': 201, 'ayah_end': 201});
      expect(d.source, 'Quran 2:201');
    });

    test('empty duas list', () async {
      final mock = MockClient((_) async => _json(_geminiOk(jsonEncode({
            'reply': "I'm not certain of an authentic dua for that.",
            'duas': <Object>[],
          }))));
      final reply = await _client(mock).suggestDuas('x', const []);
      expect(reply.duas, isEmpty);
      expect(reply.reply, contains('not certain'));
    });

    test('malformed JSON -> bad_json', () async {
      final mock = MockClient((_) async => _json(_geminiOk('Sure! Here are duas: [oops')));
      final e = await _expectLlmError(_client(mock).suggestDuas('x', const []));
      expect(e.kind, 'bad_json');
    });

    test('401 and 400 API_KEY_INVALID -> bad_key', () async {
      final e401 = await _expectLlmError(_client(MockClient((_) async => _json({
            'error': {'code': 401, 'message': 'Bad key $_key', 'status': 'UNAUTHENTICATED'},
          }, 401))).suggestDuas('x', const []));
      expect(e401.kind, 'bad_key');

      final e400 = await _expectLlmError(_client(MockClient((_) async => _json({
            'error': {
              'code': 400,
              'message': 'API key not valid. Please pass a valid API key.',
              'status': 'INVALID_ARGUMENT',
              'details': [
                {
                  '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
                  'reason': 'API_KEY_INVALID',
                },
              ],
            },
          }, 400))).suggestDuas('x', const []));
      expect(e400.kind, 'bad_key');
    });

    test('403 -> denied with friendly message', () async {
      final e = await _expectLlmError(_client(MockClient((_) async => _json({
            'error': {'code': 403, 'message': 'Permission denied for $_key', 'status': 'PERMISSION_DENIED'},
          }, 403))).suggestDuas('x', const []));
      expect(e.kind, 'denied');
      expect(e.userMessage, contains('403'));
    });

    test('429 -> rate_limit, 503 -> server, other 400 -> server (key redacted)', () async {
      final e429 = await _expectLlmError(_client(MockClient((_) async => _json({
            'error': {'code': 429, 'message': 'Quota', 'status': 'RESOURCE_EXHAUSTED'},
          }, 429))).suggestDuas('x', const []));
      expect(e429.kind, 'rate_limit');
      final e503 = await _expectLlmError(
          _client(MockClient((_) async => http.Response('down', 503))).suggestDuas('x', const []));
      expect(e503.kind, 'server');
      final e400 = await _expectLlmError(_client(MockClient((_) async => _json({
            'error': {'code': 400, 'message': 'Something about $_key', 'status': 'INVALID_ARGUMENT'},
          }, 400))).suggestDuas('x', const []));
      expect(e400.kind, 'server');
      expect(e400.userMessage, contains('***'));
    });

    test('503 high demand retries, then falls back to the lite model', () async {
      final calls = <String>[];
      final client = _client(MockClient((req) async {
        calls.add(req.url.path);
        if (req.url.path.contains('gemini-flash-lite-latest')) {
          return _json({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'OK'},
                  ],
                },
              },
            ],
          }, 200);
        }
        return http.Response('{"error":{"code":503,"status":"UNAVAILABLE"}}', 503);
      }));
      expect(await client.testConnection(), contains('Gemini'));
      expect(calls, hasLength(3));
      expect(calls.first, contains('gemini-flash-latest'));
      expect(calls.last, contains('gemini-flash-lite-latest'));
    });

    test('network failure -> offline, slow -> timeout', () async {
      final off = await _expectLlmError(_client(MockClient((_) async {
        throw http.ClientException('Failed host lookup');
      })).suggestDuas('x', const []));
      expect(off.kind, 'offline');

      final slow = await _expectLlmError(_client(
        MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return _json(_geminiOk('{}'));
        }),
        timeout: const Duration(milliseconds: 20),
      ).suggestDuas('x', const []));
      expect(slow.kind, 'timeout');
    });

    test('translate returns plain text without JSON mode', () async {
      late Map<String, dynamic> body;
      final mock = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return _json(_geminiOk('  "اے ہمارے رب"  '));
      });
      final t = await _client(mock).translate('Our Lord', 'Urdu');
      expect(t, 'اے ہمارے رب');
      expect((body['generationConfig'] as Map).containsKey('responseMimeType'), isFalse);
      expect(jsonEncode(body['systemInstruction']), contains('Urdu'));
    });

    test('testConnection', () async {
      final ok = await _client(MockClient((_) async => _json(_geminiOk('OK')))).testConnection();
      expect(ok, contains('Gemini'));
    });
  });

  group('Anthropic', () {
    const settings = AppSettings(llmProvider: 'anthropic', anthropicApiKey: _key);

    test('success: headers, body and text blocks only', () async {
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        return _json({
          'id': 'msg_1',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': '', 'signature': 'x'},
            {'type': 'text', 'text': '```json\n${jsonEncode(_duaJson)}\n```'},
          ],
          'stop_reason': 'end_turn',
        });
      });
      final reply = await _client(mock, settings: settings).suggestDuas('help', const [
        ChatMessage(role: 'assistant', text: 'Welcome'),
        ChatMessage(role: 'user', text: 'hi'),
        ChatMessage(role: 'assistant', text: 'Hello', payloadJson: '{"reply":"Hello","duas":[]}'),
      ]);
      expect(captured.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(captured.headers['x-api-key'], _key);
      expect(captured.headers['anthropic-version'], '2023-06-01');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['model'], 'claude-sonnet-5-5');
      expect(body['system'], contains('JSON ONLY'));
      expect(body.containsKey('temperature'), isFalse);
      final messages = body['messages'] as List;
      expect(messages.first['role'], 'user'); // leading assistant dropped
      expect(messages[1]['content'], contains('"reply":"Hello"'));
      expect(messages.last, {'role': 'user', 'content': 'help'});
      expect(reply.duas.single.title, 'Good in this world and the next');
    });

    test('401 -> bad_key, 529 -> server, refusal -> server', () async {
      final e401 = await _expectLlmError(_client(MockClient((_) async => _json({
            'type': 'error',
            'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'},
          }, 401)), settings: settings).suggestDuas('x', const []));
      expect(e401.kind, 'bad_key');
      final e529 = await _expectLlmError(_client(MockClient((_) async => _json({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          }, 529)), settings: settings).suggestDuas('x', const []));
      expect(e529.kind, 'server');
      final refusal = await _expectLlmError(_client(MockClient((_) async => _json({
            'type': 'message',
            'content': <Object>[],
            'stop_reason': 'refusal',
          })), settings: settings).suggestDuas('x', const []));
      expect(refusal.kind, 'server');
    });

    test('missing key -> no_key without a request', () async {
      var called = false;
      final e = await _expectLlmError(_client(MockClient((_) async {
        called = true;
        return http.Response('', 200);
      }), settings: const AppSettings(llmProvider: 'anthropic')).suggestDuas('x', const []));
      expect(e.kind, 'no_key');
      expect(called, isFalse);
    });
  });

  group('parseReply', () {
    test('fenced JSON and surrounding text', () {
      final r = parseReply('Here you go:\n```json\n${jsonEncode(_duaJson)}\n```\nMay Allah accept.');
      expect(r.duas, hasLength(1));
      final r2 = parseReply('Sure. ${jsonEncode(_duaJson)} Done.');
      expect(r2.duas, hasLength(1));
    });

    test('lenient fields, max 3 duas, entries without Arabic dropped', () {
      final r = parseReply(jsonEncode({
        'reply': 'ok',
        'duas': [
          for (var i = 0; i < 5; i++)
            {'title': 'd$i', 'arabic': 'رَبِّ', 'repeat': '500', 'source': 'Sahih Muslim 1'},
          {'title': 'no arabic'},
        ],
      }));
      expect(r.duas, hasLength(3));
      expect(r.duas.first.repeat, 100);
      expect(r.duas.first.kind, 'hadith');
      expect(r.duas.first.quran, isNull);
      expect(r.duas.first.category, 'General');
    });

    test('malformed -> bad_json; toJson round trip', () {
      expect(() => parseReply('not json at all'),
          throwsA(isA<LlmException>().having((e) => e.kind, 'kind', 'bad_json')));
      final r = parseReply(jsonEncode(_duaJson));
      final again = ChatReply.fromJson(r.toJson());
      expect(again.reply, r.reply);
      expect(again.duas.single.arabic, r.duas.single.arabic);
      expect(again.duas.single.quran, r.duas.single.quran);
    });

    test('empty reply and duas gets a fallback text', () {
      final r = parseReply('{"reply":"","duas":[]}');
      expect(r.reply, isNotEmpty);
      expect(r.duas, isEmpty);
    });
  });

  test('timeout default is 60 s', () {
    expect(LlmClient(settings: () => const AppSettings(), client: MockClient((_) async => http.Response('', 200))).timeout,
        const Duration(seconds: 60));
  });
}
