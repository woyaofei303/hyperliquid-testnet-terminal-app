// K 线周期栏与四列选择弹层。快捷周期保存在设备偏好中，网络订阅交给父组件切换。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme.dart';

const _standard = [
  'line',
  '1m',
  '5m',
  '15m',
  '30m',
  '1h',
  '4h',
  '1d',
  '1w',
  '1M',
];
const _all = [
  'line',
  '1m',
  '3m',
  '5m',
  '15m',
  '30m',
  '1h',
  '2h',
  '4h',
  '8h',
  '12h',
  '1d',
  '3d',
  '1w',
  '1M',
];
const _defaultQuick = ['line', '1m', '5m', '15m', '1h'];
const _preferenceKey = 'chart.quickIntervals';

String _label(String period, bool en) {
  if (period == 'line') return en ? 'Line' : '分时';
  if (en) return period;
  return period.substring(0, period.length - 1) +
      const {'m': '分', 'h': '时', 'd': '日', 'w': '周', 'M': '月'}[period.substring(
        period.length - 1,
      )]!;
}

/// 只管理周期选择和快捷项偏好，onSelect 把 API 周期键传给 MarketQuotePanel。
class ChartPeriodBar extends StatefulWidget {
  const ChartPeriodBar({
    super.key,
    required this.selected,
    required this.english,
    required this.onSelect,
  });
  final String selected;
  final bool english;
  final ValueChanged<String> onSelect;

  @override
  State<ChartPeriodBar> createState() => _ChartPeriodBarState();
}

class _ChartPeriodBarState extends State<ChartPeriodBar> {
  List<String> _quick = _defaultQuick;
  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 过滤设备中已失效的周期，并限制为五项；读取失败继续使用默认快捷项。
  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_preferenceKey) ?? _defaultQuick;
      final quick = _all
          .where(saved.contains)
          .take(_defaultQuick.length)
          .toList();
      if (mounted && quick.isNotEmpty) setState(() => _quick = quick);
    } on Exception {
      // 读取偏好失败时仍可使用默认周期栏。
    }
  }

  /// 弹层编辑使用临时 draft，点击保存且持久化成功之后才修改正式快捷栏。
  Future<void> _openPicker() async {
    final en = widget.english;
    var editing = false;
    var showAll = !_standard.contains(widget.selected);
    final draft = _quick.toSet();
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: AppColors.panel,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          final options = editing || showAll ? _all : _standard;
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          editing
                              ? (en ? 'Quick intervals' : '时间周期偏好')
                              : (en ? 'More intervals' : '更多时间周期'),
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (!editing)
                        TextButton(
                          onPressed: () => update(() => showAll = !showAll),
                          child: Text(
                            showAll
                                ? (en ? 'Common' : '常用')
                                : (en ? 'All' : '全部'),
                          ),
                        ),
                    ],
                  ),
                  if (editing)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        en
                            ? 'Choose up to five shortcuts · ${draft.length}/5'
                            : '选择 1 至 5 个快捷周期 · ${draft.length}/5',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    ),
                  const SizedBox(height: 14),
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    mainAxisExtent: 44,
                    children: [
                      for (final p in options)
                        Builder(
                          builder: (_) {
                            final selected = editing
                                ? draft.contains(p)
                                : p == widget.selected;
                            final enabled =
                                !editing ||
                                selected ||
                                draft.length < _defaultQuick.length;
                            return Semantics(
                              selected: selected,
                              button: true,
                              enabled: enabled,
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  foregroundColor: AppColors.text,
                                  disabledForegroundColor: AppColors.muted
                                      .withValues(alpha: .45),
                                  side: BorderSide(
                                    color: selected
                                        ? AppColors.accent
                                        : AppColors.border,
                                  ),
                                  backgroundColor: selected
                                      ? AppColors.accent.withValues(alpha: .06)
                                      : null,
                                ),
                                onPressed: !enabled
                                    ? null
                                    : () {
                                        if (editing) {
                                          update(() {
                                            if (selected) {
                                              draft.remove(p);
                                            } else {
                                              draft.add(p);
                                            }
                                          });
                                        } else {
                                          Navigator.pop(sheet, p);
                                        }
                                      },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Center(child: Text(_label(p, en))),
                                    if (selected)
                                      const Align(
                                        alignment: Alignment.topRight,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: AppColors.accent,
                                            borderRadius: BorderRadius.only(
                                              topRight: Radius.circular(4),
                                              bottomLeft: Radius.circular(8),
                                            ),
                                          ),
                                          child: Padding(
                                            padding: EdgeInsets.all(2),
                                            child: Icon(
                                              Icons.check,
                                              size: 10,
                                              color: AppColors.canvas,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  if (editing)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: FilledButton(
                        onPressed: draft.isEmpty
                            ? null
                            : () => Navigator.pop(sheet, 'save'),
                        child: Text(en ? 'Save' : '保存'),
                      ),
                    )
                  else
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        en ? 'Quick interval preferences' : '选择时间周期偏好',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => update(() => editing = true),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || chosen == null) return;
    if (chosen != 'save') {
      widget.onSelect(chosen);
      return;
    }
    // 按预设周期顺序保存，避免 Set 的点选顺序改变顶部布局。
    final selected = _all.where(draft.contains).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setStringList(_preferenceKey, selected)) {
        throw Exception('Failed to store quick intervals');
      }
      if (mounted) setState(() => _quick = selected);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(en ? 'Could not save shortcuts' : '快捷周期保存失败')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.english;
    return Row(
      children: [
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in _quick)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(37, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      foregroundColor: widget.selected == p
                          ? AppColors.accent
                          : AppColors.muted,
                    ),
                    onPressed: () => widget.onSelect(p),
                    child: Text(
                      _label(p, en),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Tooltip(
          message: en ? 'More intervals' : '更多周期',
          child: TextButton(
            onPressed: _openPicker,
            style: TextButton.styleFrom(
              minimumSize: const Size(46, 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _quick.contains(widget.selected)
                      ? (en ? 'More' : '更多')
                      : _label(widget.selected, en),
                  style: TextStyle(
                    fontSize: 12,
                    color: _quick.contains(widget.selected)
                        ? AppColors.muted
                        : AppColors.accent,
                  ),
                ),
                const Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: AppColors.muted,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
