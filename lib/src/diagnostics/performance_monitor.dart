// 本地性能采样：以设备刷新率判断 UI / raster 各自超预算，不能把两者相加当掉帧。
import 'dart:async';
import 'dart:ui';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'app_diagnostics.dart';

/// 一个采样窗口的耗时分布，毫秒；P95 使用最近 600 帧，计数包含窗口内所有帧。
class FrameWindow {
  final _build = <double>[];
  final _raster = <double>[];
  int frames = 0, slow = 0;
  void add(double buildMs, double rasterMs, double budgetMs) {
    frames++;
    if (buildMs > budgetMs || rasterMs > budgetMs) slow++;
    _build.add(buildMs);
    _raster.add(rasterMs);
    if (_build.length > 600) {
      _build.removeAt(0);
      _raster.removeAt(0);
    }
  }

  Map<String, Object?> snapshot() {
    double p95(List<double> values) {
      if (values.isEmpty) return 0;
      final sorted = values.toList()..sort();
      return sorted[(sorted.length * .95).ceil() - 1];
    }

    return {
      'frames': frames,
      'slowFrames': slow,
      'buildP95Ms': p95(_build),
      'rasterP95Ms': p95(_raster),
    };
  }
}

/// 由启动入口注册一次；切后台停止采样，暂停前刷写日志，避免后台时间污染指标。
class PerformanceMonitor with WidgetsBindingObserver {
  final log = AppDiagnostics.instance;
  FrameWindow _window = FrameWindow();
  Timer? _timer;
  bool _foreground = true;
  void start() {
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _flush());
  }

  double get _refreshRate {
    final hz =
        PlatformDispatcher.instance.views.firstOrNull?.display.refreshRate ??
        60;
    return hz > 0 && hz.isFinite ? hz : 60;
  }

  void _onFrames(List<FrameTiming> timings) {
    if (!_foreground) return;
    for (final timing in timings) {
      _window.add(
        timing.buildDuration.inMicroseconds / 1000,
        timing.rasterDuration.inMicroseconds / 1000,
        1000 / _refreshRate,
      );
    }
  }

  void _flush() {
    if (!_foreground) return;
    final snapshot = {
      ..._window.snapshot(),
      'refreshHz': _refreshRate,
      'rssMb': ProcessInfo.currentRss / (1024 * 1024),
    };
    log.metrics['frames'] = snapshot;
    log.record(
      'performance',
      'window.10s',
      data: {...snapshot, 'counts': log.takeCounters()},
    );
    _window = FrameWindow();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _flush();
      unawaited(log.flush());
    }
    _foreground = state == AppLifecycleState.resumed;
    _window = FrameWindow();
  }

  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    WidgetsBinding.instance.removeObserver(this);
  }
}
