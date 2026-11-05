// 开发排障面板：从首页实时状态入口打开，查看有界日志并手动复制，无上传动作。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_diagnostics.dart';

/// 两秒刷新一次，避免每条行情推送都触发诊断页面重建；关闭页面即释放定时器。
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.english});
  final bool english;
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _log = AppDiagnostics.instance;
  Timer? _timer;
  String _filter = 'all';
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.english;
    final rows = _log.events
        .where(
          (e) =>
              _filter == 'all' ||
              (_filter == 'errors'
                  ? e['level'] != 'info'
                  : e['category'].toString().startsWith(_filter)),
        )
        .toList();
    final frames = _log.metrics['frames'];
    return Scaffold(
      appBar: AppBar(
        title: Text(en ? 'Diagnostics' : '诊断与日志'),
        actions: [
          IconButton(
            tooltip: en ? 'Copy report' : '复制诊断报告',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _log.export()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(en ? 'Report copied' : '已复制诊断报告')),
                );
              }
            },
          ),
          IconButton(
            tooltip: en ? 'Clear local logs' : '清空本地记录',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await _log.clear();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sentry: ${_log.remote} · ${en ? 'Storage' : '本地存储'}: ${_log.persistence}',
                ),
                const SizedBox(height: 6),
                Text(
                  en
                      ? '200 session events; up to 60 persisted summaries. Configured does not mean delivered.'
                      : '会话最多 200 条；落盘最多 60 条摘要。“configured”仅表示已配置，不能证明上报成功。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'HTTP P95: ${(_log.metrics['httpP95Ms'] as num?)?.toStringAsFixed(1) ?? '—'} ms · WS: ${_log.metrics['wsState'] ?? '—'}',
                ),
                if (frames is Map)
                  Text(
                    'UI P95: ${(frames['buildP95Ms'] as num).toStringAsFixed(1)} ms · Raster P95: ${(frames['rasterP95Ms'] as num).toStringAsFixed(1)} ms',
                  ),
                Text(
                  en
                      ? 'Use a physical device in profile mode for performance conclusions.'
                      : '性能结论请用真机 profile 模式；模拟器数据仅用于定位。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<String>(
                        value: _filter,
                        isExpanded: true,
                        items: [
                          for (final entry in {
                            'all': en ? 'All' : '全部',
                            'errors': en ? 'Errors / warnings' : '错误 / 警告',
                            'http': 'HTTP',
                            'ws': 'WebSocket',
                            'performance': en ? 'Performance' : '性能',
                            'chart': en ? 'Chart' : '图表',
                          }.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _filter = value ?? 'all'),
                      ),
                    ),
                    if (!kReleaseMode)
                      TextButton(
                        onPressed: () {
                          // 人工点击才生成无业务数据的诊断事件，不制造崩溃或金融请求。
                          _log.error(
                            'diagnostics.probe',
                            const DiagnosticProbe(),
                            StackTrace.current,
                          );
                          setState(() {});
                        },
                        child: Text(en ? 'Test event' : '生成测试事件'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(child: Text(en ? 'No records yet' : '暂无记录'))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, index) {
                      final row = rows[index];
                      return ExpansionTile(
                        key: ValueKey('${row['time']}-${row['operation']}'),
                        title: Text(
                          '${row['level']} · ${row['operation']}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          '${row['time']}',
                          style: const TextStyle(fontSize: 10),
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              const JsonEncoder.withIndent('  ').convert(row),
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 固定类型帮助在 Sentry 中检索联调事件，不能用于判断实际业务稳定性。
class DiagnosticProbe implements Exception {
  const DiagnosticProbe();
}
