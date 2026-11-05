// 启动入口。先建立 Flutter 与平台插件的绑定，再挂载根组件 TerminalApp。

import 'package:flutter/material.dart';

import 'src/app/terminal_app.dart';
import 'src/diagnostics/sentry_monitoring.dart';
import 'src/diagnostics/performance_monitor.dart';

/// 进程入口，插件访问应在 ensureInitialized 完成之后发生。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeMonitoring();
  PerformanceMonitor().start();
  runApp(const TerminalApp());
}
