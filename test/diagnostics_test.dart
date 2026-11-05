// 验证日志的隐私边界和容量，不依赖 Sentry 账号或真实交易。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:hyperliquid_testnet_terminal/src/diagnostics/sentry_monitoring.dart';
import 'package:hyperliquid_testnet_terminal/src/diagnostics/performance_monitor.dart';
import 'package:hyperliquid_testnet_terminal/src/chart/chart_candle.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hyperliquid_testnet_terminal/src/diagnostics/diagnostic_http_client.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyperliquid_testnet_terminal/src/diagnostics/app_diagnostics.dart';

void main() {
  test('导出日志有界且不包含密钥、地址或原始异常消息', () {
    final log = AppDiagnostics(capacity: 3, console: false);
    log.record(
      'http',
      'response',
      data: {
        'privateKey': 'fixture-private-secret',
        'nested': {'Authorization': 'Bearer fixture-token'},
        'wallet': '0x1111111111111111111111111111111111111111',
        'price': 123.45,
        'v': '12.34',
        's': 'BTC',
      },
    );
    log.error(
      'chart.snapshot',
      StateError('fixture-sensitive-error'),
      StackTrace.current,
    );
    final text = log.export();
    expect(text, isNot(contains('fixture-private-secret')));
    expect(text, isNot(contains('fixture-token')));
    expect(text, isNot(contains('0x111111')));
    expect(text, isNot(contains('fixture-sensitive-error')));
    expect(text, contains('123.45'));
    expect(text, contains('12.34'));
    expect(text, contains('BTC'));
    for (var i = 0; i < 10; i++) {
      log.record('test', 'event');
    }
    expect((jsonDecode(log.export()) as Map)['events'], hasLength(3));
  });
  test('HTTP 正文保持原样，金融请求不进入日志，监控失败不影响响应', () async {
    final log = AppDiagnostics(console: false);
    log.reporter = (_, _, _) async => throw StateError('offline');
    final response = utf8.encode(
      '{"status":"ok","signature":"fixture-signed-data"}',
    );
    final client = DiagnosticHttpClient(
      inner: MockClient((request) async {
        expect(jsonDecode(request.body)['signature'], 'fixture-signed-data');
        return http.Response.bytes(response, 200);
      }),
      log: log,
      bodies: true,
    );
    final result = await client.post(
      Uri.parse('https://api.hyperliquid-testnet.xyz/exchange'),
      body: jsonEncode({'signature': 'fixture-signed-data'}),
    );
    expect(result.bodyBytes, response);
    expect(log.export(), contains('http.complete'));
    expect(log.export(), isNot(contains('fixture-signed-data')));
    log.error('test.failure', StateError('private'), StackTrace.current);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(log.remote, 'export-failed');
    client.close();
  });
  test('同一错误去重且不同错误也受每小时预算限制', () {
    final budget = RemoteErrorBudget(limit: 2);
    final now = DateTime.utc(2026, 11, 5);
    expect(budget.allow('a', now), isTrue);
    expect(budget.allow('a', now), isFalse);
    expect(budget.allow('b', now), isTrue);
    expect(budget.allow('c', now), isFalse);
    expect(budget.allow('a', now.add(const Duration(hours: 1))), isTrue);
  });
  test('非有限价格及倒置 OHLC 不进入图表', () {
    final invalid = Candle(
      startTime: 0,
      endTime: 59999,
      open: 100,
      close: double.nan,
      high: 101,
      low: 99,
      volume: 1,
      numTrades: 1,
    );
    expect(candleIssue(invalid), 'non-finite');
    final inverted = Candle(
      startTime: 0,
      endTime: 59999,
      open: 100,
      close: 102,
      high: 101,
      low: 99,
      volume: 1,
      numTrades: 1,
    );
    expect(candleIssue(inverted), 'ohlc');
  });
  test('UI 与 raster 按各自预算计数，不将两阶段相加', () {
    final frames = FrameWindow();
    frames.add(10, 10, 16.67);
    frames.add(9, 2, 8.33);
    expect(frames.snapshot()['slowFrames'], 1);
    expect(frames.snapshot()['frames'], 2);
  });
  test('Sentry 出口不含异常消息、请求、用户、变量和 breadcrumbs', () {
    final event = SentryEvent.fromJson({
      'event_id': '11111111111111111111111111111111',
      'user': {'id': 'fixture-user'},
      'contexts': {
        'device': {'model': 'Test phone', 'id': 'fixture-device-id'},
        'trace': {
          'trace_id': '22222222222222222222222222222222',
          'op': 'app.start',
          'span_id': '3333333333333333',
          'data': {'secret': 'fixture-secret'},
        },
      },
      'request': {'url': 'https://private.test', 'data': 'fixture-body'},
      'message': {'formatted': 'fixture-message'},
      'exception': {
        'values': [
          {
            'type': 'StateError',
            'value': 'fixture-error',
            'stacktrace': {
              'frames': [
                {
                  'filename': 'lib/main.dart',
                  'function': 'main',
                  'vars': {'seed': 'fixture-seed'},
                },
              ],
            },
          },
        ],
      },
      'breadcrumbs': [
        {'message': 'fixture-crumb'},
      ],
    });
    final clean = jsonEncode(privateSentryEvent(event).toJson());
    expect(clean, isNot(contains('fixture-')));
    expect(clean, contains('lib/main.dart'));
    expect(clean, contains('StateError'));
    expect(clean, contains('Test phone'));
    expect(clean, contains('22222222222222222222222222222222'));
  });
  test('请求失败原样抛出且不自动重发', () async {
    var calls = 0;
    final failure = http.ClientException('fixture-sensitive-server-message');
    final log = AppDiagnostics(console: false);
    final client = DiagnosticHttpClient(
      log: log,
      inner: MockClient((_) async {
        calls++;
        throw failure;
      }),
    );
    await expectLater(
      client.post(Uri.parse('https://api.hyperliquid-testnet.xyz/exchange')),
      throwsA(same(failure)),
    );
    expect(calls, 1);
    expect(log.export(), isNot(contains('fixture-sensitive-server-message')));
    client.close();
  });
  test('重启后可恢复摘要，公开响应正文不落盘且旧摘要被淘汰', () async {
    SharedPreferences.setMockInitialValues({});
    final log = AppDiagnostics(console: false);
    await log.restore();
    for (var i = 0; i < 90; i++) {
      log.record('http', 'complete.$i');
    }
    log.record(
      'http.body',
      'response.body',
      data: {'body': 'fixture-public-body'},
    );
    await log.flush();
    final next = AppDiagnostics(console: false);
    await next.restore();
    expect(next.events.length, 60);
    expect(next.export(), contains('complete.89'));
    expect(next.export(), isNot(contains('complete.0"')));
    expect(next.export(), isNot(contains('fixture-public-body')));
    await log.clear();
    await next.clear();
  });
  test('公开正文白名单不能被其他域名的同名接口复用', () async {
    final log = AppDiagnostics(console: false);
    final client = DiagnosticHttpClient(
      log: log,
      bodies: true,
      inner: MockClient(
        (_) async => http.Response('{"value":"fixture-private-response"}', 200),
      ),
    );
    await client.post(
      Uri.parse('https://untrusted.example/info'),
      body: '{"type":"candleSnapshot"}',
    );
    expect(log.export(), isNot(contains('fixture-private-response')));
    client.close();
  });
}
