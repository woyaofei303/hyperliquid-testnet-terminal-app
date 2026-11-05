// Sentry 可选出口。未配置 DSN 不初始化云端；本地日志、接口与交易不依赖它成功。

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app_diagnostics.dart';

/// 云端只保留异常类型、代码位置和版本；原始消息、变量、用户和网络正文全部移除。
SentryEvent privateSentryEvent(SentryEvent event) {
  final source = event.toJson();
  final safe = <String, dynamic>{
    for (final key in [
      'event_id',
      'timestamp',
      'platform',
      'level',
      'release',
      'dist',
      'environment',
      'sdk',
      'debug_meta',
    ])
      if (source.containsKey(key)) key: source[key],
  };
  // 保留排障需要的型号/系统版本与 trace 关联；不保留设备 ID、用户或动态 data。
  const contextFields = {
    'device': [
      'family',
      'model',
      'brand',
      'arch',
      'screen_width_pixels',
      'screen_height_pixels',
      'simulator',
    ],
    'os': ['name', 'version', 'build'],
    'app': ['app_identifier', 'app_version', 'app_build'],
    'runtime': ['name', 'version'],
    'trace': [
      'trace_id',
      'span_id',
      'parent_span_id',
      'op',
      'status',
      'origin',
    ],
  };
  final contexts = source['contexts'];
  if (contexts is Map) {
    safe['contexts'] = {
      for (final entry in contextFields.entries)
        if (contexts[entry.key] is Map)
          entry.key: {
            for (final key in entry.value)
              if ((contexts[entry.key] as Map).containsKey(key))
                key: contexts[entry.key][key],
          },
    };
  }
  final exceptions = event.exceptions;
  if (exceptions != null) {
    safe['exception'] = {
      'values': exceptions.map((exception) {
        final json = exception.toJson();
        final frames = exception.stackTrace?.frames;
        return {
          'type': exception.type,
          'value': '[message omitted]',
          if (json['mechanism'] is Map)
            'mechanism': {
              'type': json['mechanism']['type'],
              'handled': json['mechanism']['handled'],
            },
          if (frames != null)
            'stacktrace': {
              'frames': frames.map((frame) {
                final source = frame.toJson();
                return {
                  for (final key in [
                    'filename',
                    'function',
                    'module',
                    'lineno',
                    'colno',
                    'in_app',
                    'instruction_addr',
                    'package',
                  ])
                    if (source.containsKey(key)) key: source[key],
                };
              }).toList(),
            },
        };
      }).toList(),
    };
  }
  final operation = event.tags?['operation'];
  safe['tags'] = {'network': 'testnet', 'operation': ?operation};
  return SentryEvent.fromJson(safe);
}

/// 先初始化 SDK，再叠加本地捕获，保留 SDK/Flutter 原处理器并避免重复上传。
Future<void> initializeMonitoring() async {
  final log = AppDiagnostics.instance;
  await log.restore();
  const dsn = String.fromEnvironment('SENTRY_DSN');
  final budget = RemoteErrorBudget();
  if (dsn.isNotEmpty) {
    try {
      await SentryFlutter.init((options) {
        options.dsn = dsn;
        options.environment = const String.fromEnvironment(
          'APP_ENV',
          defaultValue: 'development',
        );
        // 默认用 SDK 从安装包读取版本；CI 可覆盖为与符号文件匹配的 release。
        const release = String.fromEnvironment('SENTRY_RELEASE');
        if (release.isNotEmpty) options.release = release;
        options.sendDefaultPii = false;
        options.enablePrintBreadcrumbs = false;
        options.recordHttpBreadcrumbs = false;
        options.enableAutoNativeBreadcrumbs = false;
        options.enableUserInteractionBreadcrumbs = false;
        options.enableUserInteractionTracing = false;
        options.attachScreenshot = false;
        options.attachViewHierarchy = false;
        options.replay.sessionSampleRate = 0;
        options.replay.onErrorSampleRate = 0;
        // 原生崩溃不经过 Dart beforeSend，先关闭，完成原生脱敏验收后再单独接入。
        options.enableNativeCrashHandling = false;
        options.enableWatchdogTerminationTracking = false;
        options.anrEnabled = false;
        options.beforeBreadcrumb = (_, _) => null;
        options.beforeSendLog = (_, _) => null;
        options.beforeSendMetric = (_, _) => null;
        final sample =
            double.tryParse(
              const String.fromEnvironment(
                'SENTRY_TRACES_SAMPLE_RATE',
                defaultValue: '0',
              ),
            ) ??
            0;
        options.tracesSampleRate = sample.isFinite ? sample.clamp(0, 1) : 0;
        // 只采集框架性能；不把交易、RPC 或 WalletConnect 参数作为 span 属性。
        options.tracePropagationTargets.clear();
        options.beforeSend = (event, hint) {
          final clean = privateSentryEvent(event);
          final fingerprint =
              '${clean.exceptions?.map((e) => '${e.type}:${e.stackTrace?.frames.lastOrNull?.function}').join('|')}:${clean.tags?['operation']}';
          if (!budget.allow(fingerprint, DateTime.now())) {
            log.suppressedRemote++;
            return null;
          }
          return clean;
        };
      });
      log.remote = 'configured'; // 配置成功不代表云端已收到，也无法据此得知剩余额度。
      log.reporter = (operation, error, stack) async {
        await Sentry.captureException(
          error,
          stackTrace: stack,
          withScope: (scope) {
            scope.setTag('operation', operation);
          },
        );
      };
    } catch (error, stack) {
      log.remote = 'init-failed';
      log.error('monitoring.init', error, stack, remote: false);
    }
  }
  final flutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    log.error(
      'flutter.unhandled',
      details.exception,
      details.stack ?? StackTrace.current,
      remote: false,
    );
    flutterHandler?.call(details);
  };
  final platformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    log.error('dart.unhandled', error, stack, remote: false);
    return platformHandler?.call(error, stack) ?? false;
  };
  log.record(
    'app',
    'start',
    data: {
      'mode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
    },
  );
}
