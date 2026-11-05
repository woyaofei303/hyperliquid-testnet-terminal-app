// 本地诊断入口：业务只提交固定操作名和必要字段，不提交原始异常消息或签名内容。
// 有界记录独立于 Sentry；最近摘要存普通偏好，详细公开行情仅留当前会话。
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 统一记录接口、状态和错误。日志失败不改变业务返回值，不负责业务重试。
class AppDiagnostics {
  AppDiagnostics({this.capacity = 200, this.console = kDebugMode});
  static final instance = AppDiagnostics();
  static const _storageKey = 'diagnostics.recent.v1';
  static final _traceKey = Object();
  final int capacity;
  final bool console;
  final _events = Queue<Map<String, Object?>>();
  final _counters = <String, int>{};
  final session = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  int _sequence = 0;
  SharedPreferences? _preferences;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  String persistence = 'memory';
  String remote = 'disabled';
  int suppressedRemote = 0;
  final metrics = <String, Object?>{};
  Future<void> Function(String operation, Object error, StackTrace stack)?
  reporter;

  String get traceId => Zone.current[_traceKey] as String? ?? session;
  String nextId() => '$session-${++_sequence}';

  /// 把一次操作中的多个 HTTP 请求关联起来；不会添加交易请求头或修改签名。
  Future<T> trace<T>(String operation, Future<T> Function() action) =>
      runZoned(() async {
        record('action', operation);
        return action();
      }, zoneValues: {_traceKey: nextId()});

  /// 启动时恢复最近摘要；存储不可用时降级到内存，不阻止 App 启动。
  Future<void> restore() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      final data = jsonDecode(_preferences!.getString(_storageKey) ?? '[]');
      if (data is List) {
        for (final row in data.whereType<Map>().take(60)) {
          _events.add(Map<String, Object?>.from(redact(row) as Map));
        }
      }
      persistence = 'ready';
    } catch (_) {
      persistence = 'unavailable';
    }
  }

  /// data 必须由调用方选取；金融请求的正文一律不传入本方法。
  void record(
    String category,
    String operation, {
    String level = 'info',
    Map<String, Object?> data = const {},
  }) {
    final event = <String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'session': session,
      'traceId': traceId,
      'level': level,
      'category': category,
      'operation': operation,
      'data': redact(data),
    };
    final serialized = jsonEncode(event['data']);
    if (serialized.length > 8000) {
      event['data'] = {
        'preview': serialized.substring(0, 8000),
        'truncated': true,
      };
    }
    _events.add(event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
    if (console) {
      final line = jsonEncode(event);
      developer.log(line, name: 'HL');
      debugPrint('[HL] $line');
    }
    if (_preferences != null && _saveTimer == null) {
      _saveTimer = Timer(const Duration(seconds: 2), () {
        _saveTimer = null;
        unawaited(flush());
      });
    }
  }

  /// 保留异常类型与堆栈；异常消息可能回显私钥、RPC 参数或服务端正文，不能收集。
  void error(
    String operation,
    Object error,
    StackTrace stack, {
    bool remote = true,
  }) {
    record(
      'error',
      operation,
      level: 'error',
      data: {'type': error.runtimeType.toString(), 'stack': stack.toString()},
    );
    final send = reporter;
    if (remote && send != null) {
      unawaited(
        Future<void>(() async {
          try {
            await send(operation, error, stack);
          } catch (_) {
            this.remote = 'export-failed';
          }
        }),
      );
    }
  }

  /// 高频行情只累计计数，由每十秒的性能采样统一输出。
  void count(String key) {
    _counters.update(key, (v) => v + 1, ifAbsent: () => 1);
  }

  Map<String, int> takeCounters() {
    final result = Map<String, int>.of(_counters);
    _counters.clear();
    return result;
  }

  /// 最近 60 条摘要最多约 64 KB；详细行情正文不落盘，旧记录会被覆盖。
  Future<void> flush() {
    final rows = _events.where((e) => e['category'] != 'http.body').toList();
    final recent = rows.skip(rows.length > 60 ? rows.length - 60 : 0).toList();
    while (utf8.encode(jsonEncode(recent)).length > 64000 &&
        recent.isNotEmpty) {
      recent.removeAt(0);
    }
    final text = jsonEncode(recent);
    _saving = _saving.then((_) async {
      try {
        await _preferences?.setString(_storageKey, text);
      } catch (_) {
        persistence = 'unavailable';
      }
    });
    return _saving;
  }

  /// 输出可复制的 JSON；没有远程网络调用，也不会自动重传历史错误。
  String export() => const JsonEncoder.withIndent('  ').convert({
    'session': session,
    'remote': remote,
    'persistence': persistence,
    'suppressedRemote': suppressedRemote,
    'metrics': metrics,
    'events': _events.toList(),
  });

  List<Map<String, Object?>> get events =>
      List.unmodifiable(_events.toList().reversed);

  Future<void> clear() async {
    _events.clear();
    await flush();
  }
}

final _secretKey = RegExp(
  r'private|secret|seed|mnemonic|password|authorization|cookie|token|signature|signed|calldata|address|account|user|wallet|destination|recipient|sender|cloid|nonce|hash',
  caseSensitive: false,
);

/// 有界递归脱敏；它是第二道防线，不能替代调用方对敏感正文的禁采规则。
Object? redact(Object? value, {int depth = 0}) {
  if (depth > 6) return '[depth-limited]';
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries.take(30))
        entry.key.toString(): _secretKey.hasMatch(entry.key.toString())
            ? '[redacted]'
            : redact(entry.value, depth: depth + 1),
    };
  }
  if (value is Iterable) {
    return value.take(20).map((v) => redact(v, depth: depth + 1)).toList();
  }
  if (value is num) return value.isFinite ? value : '[non-finite]';
  if (value == null || value is bool) return value;
  final text = value
      .toString()
      .replaceAll(RegExp(r'0x[a-fA-F0-9]{40,}'), '[redacted-hex]')
      .replaceAll(
        RegExp(r'Bearer\s+\S+', caseSensitive: false),
        '[redacted-token]',
      )
      .replaceAll(RegExp(r'https?://\S+'), '[url]');
  return text.length > 1800 ? '${text.substring(0, 1800)}…[truncated]' : text;
}

/// 每次进程运行内每小时最多 20 个 Dart 错误，同一位置一分钟只发一次。
/// shortcut: 不是组织额度控制，重启会重置；多人上线时必须在 Sentry 查看总量。
class RemoteErrorBudget {
  RemoteErrorBudget({this.limit = 20});
  final int limit;
  DateTime? _window;
  int _sent = 0;
  final _last = <String, DateTime>{};
  bool allow(String fingerprint, DateTime now) {
    if (_window == null ||
        now.difference(_window!) >= const Duration(hours: 1)) {
      _window = now;
      _sent = 0;
      _last.clear();
    }
    final previous = _last[fingerprint];
    if (_sent >= limit ||
        (previous != null &&
            now.difference(previous) < const Duration(minutes: 1))) {
      return false;
    }
    _last[fingerprint] = now;
    _sent++;
    return true;
  }
}
