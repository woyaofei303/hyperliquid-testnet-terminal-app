// SDK 和资金服务共用的 HTTP 观察器：原始请求、字节流和异常继续交给原调用方。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:hyperliquid_dart/hyperliquid_dart.dart';

import 'app_diagnostics.dart';

/// 每个调用方持有自己的 client，close 只释放其内部连接，不影响其他页面。
class DiagnosticHttpClient extends http.BaseClient {
  DiagnosticHttpClient({http.Client? inner, AppDiagnostics? log, bool? bodies})
    : _inner = inner ?? http.Client(),
      _log = log ?? AppDiagnostics.instance,
      _bodies =
          bodies ??
          (kDebugMode && const bool.fromEnvironment('APP_LOG_BODIES'));
  final http.Client _inner;
  final AppDiagnostics _log;
  final bool _bodies;
  static const _publicTypes = {
    'meta',
    'metaAndAssetCtxs',
    'spotMeta',
    'spotMetaAndAssetCtxs',
    'perpDexs',
    'outcomeMeta',
    'candleSnapshot',
    'l2Book',
    'recentTrades',
    'allMids',
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final clock = Stopwatch()..start();
    final id = _log.nextId();
    var publicBody = false;
    var kind = 'private-or-streamed';
    // 只检查已经在内存中的 Request，不读取或重新 finalize 上传流。
    if (request is http.Request &&
        request.url.host == 'api.hyperliquid-testnet.xyz' &&
        request.url.path == '/info') {
      try {
        final payload = jsonDecode(request.body);
        if (payload is Map && _publicTypes.contains(payload['type'])) {
          publicBody = true;
          kind = payload['type'] as String;
          if (_bodies) {
            _log.record(
              'http.body',
              'http.request.body',
              data: {'requestId': id, 'body': payload},
            );
          }
        }
      } catch (_) {
        /* 非 JSON 正文只记录传输摘要。 */
      }
    }
    final endpoint = switch (request.url.host) {
      'api.hyperliquid-testnet.xyz' =>
        request.url.path == '/info'
            ? 'hyperliquid.info'
            : 'hyperliquid.exchange',
      'sepolia-rollup.arbitrum.io' => 'arbitrum.rpc',
      'rpc.hyperliquid-testnet.xyz' => 'hyperliquid.rpc',
      'dev.indexer.api.across.to' => 'across.indexer',
      _ => 'other',
    };
    final metadata = <String, Object?>{
      'requestId': id,
      'endpoint': endpoint,
      'method': request.method,
      'kind': kind,
    };
    _log.record('http', 'http.start', data: metadata);
    try {
      final response = await _inner.send(request);
      final preview = <int>[];
      var bytes = 0;
      var complete = false;
      var failed = false;
      final stream = response.stream.transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            bytes += chunk.length;
            if (_bodies && publicBody && bytes <= 128 * 1024) {
              preview.addAll(chunk);
            }
            sink.add(chunk);
          },
          handleError: (Object error, StackTrace stack, sink) {
            failed = true;
            _log.record(
              'http',
              'http.stream.error',
              level: 'warning',
              data: {...metadata, 'errorType': error.runtimeType.toString()},
            );
            sink.addError(error, stack);
          },
          handleDone: (sink) {
            if (!complete) {
              complete = true;
              _log.record(
                'http',
                'http.complete',
                level: failed || response.statusCode >= 400
                    ? 'warning'
                    : 'info',
                data: {
                  ...metadata,
                  'status': response.statusCode,
                  'bytes': bytes,
                  'durationMs': clock.elapsedMicroseconds / 1000,
                },
              );
              _recordLatency(
                clock.elapsedMicroseconds / 1000,
                failed || response.statusCode >= 400,
              );
              if (_bodies && publicBody && !failed) {
                Object? body;
                try {
                  body = bytes <= 128 * 1024
                      ? jsonDecode(utf8.decode(preview))
                      : '[body too large]';
                } catch (_) {
                  body = '[non-JSON body omitted]';
                }
                _log.record(
                  'http.body',
                  'http.response.body',
                  data: {'requestId': id, 'body': body},
                );
              }
            }
            sink.close();
          },
        ),
      );
      return http.StreamedResponse(
        stream,
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (error) {
      _log.record(
        'http',
        'http.error',
        level: 'warning',
        data: {
          ...metadata,
          'durationMs': clock.elapsedMicroseconds / 1000,
          'errorType': error.runtimeType.toString(),
        },
      );
      _recordLatency(clock.elapsedMicroseconds / 1000, true);
      rethrow;
    }
  }

  void _recordLatency(double ms, bool failed) {
    _log.count(failed ? 'http.failed' : 'http.completed');
    // 最近 100 个完成请求的全局延迟；不是服务端 P95，也不包含被取消的流。
    final samples = List<double>.from(_log.metrics['httpMs'] as List? ?? [])
      ..add(ms);
    if (samples.length > 100) samples.removeAt(0);
    final sorted = samples.toList()..sort();
    _log.metrics['httpMs'] = samples;
    _log.metrics['httpP95Ms'] = sorted[(sorted.length * .95).ceil() - 1];
  }

  @override
  void close() => _inner.close();
}

/// 创建固定测试网的可观测 transport，保留 SDK 原有协议与错误处理。
HttpTransport diagnosticTransport() =>
    HttpTransport(isTestnet: true, client: DiagnosticHttpClient());
InfoClient diagnosticInfo() => InfoClient(transport: diagnosticTransport());
