// K 线绘制与手势代理。固定层画网格和坐标，滚动层画蜡烛与指标，覆盖层处理交互。
// 数据已经在 ChartCandle 中准备好，这一层负责把价格和时间映射到屏幕位置。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;
import 'package:kline_flutter/kline_flutter.dart';

import '../app/theme.dart';
import 'chart_candle.dart';
import 'chart_overlay.dart';

typedef CandleChartContext = KLineChartContext<ChartCandle>;
typedef CandleLayoutNode = KLineLayoutNode<ChartCandle>;

final _price = NumberFormat('#,##0.########', 'en_US');
const chartCandleWidth = 5.6, chartCandleSpacing = 1.4, chartTailFraction = .25;

/// 主图与副图统一高度比例，rightInset 分别服务于滚动范围和实际绘图裁剪。
KLineLayoutConfig chartLayout(double width, {required double rightInset}) =>
    KLineLayoutConfig(
      mainChartHeight: (width * .94).clamp(230, 420),
      secondaryPaneHeight: (width * .285).clamp(76, 118),
      secondaryContentVerticalPadding: 15,
      candleWidth: chartCandleWidth,
      candleSpacing: chartCandleSpacing,
      chartPadding: EdgeInsets.only(right: rightInset),
      indicatorSelectorHeight: 0,
      contentPadding: const EdgeInsets.fromLTRB(0, 25, 0, 26),
    );

/// 根据真实价格文字测量纵轴宽度，长价格不会靠固定空白宽度兜底。
double _axisWidth(double price) {
  final text = TextPainter(
    text: TextSpan(
      text: _price.format(price),
      style: const TextStyle(
        fontSize: 11.5,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = math.max(38.0, text.width.ceilToDouble() + 14);
  text.dispose();
  return width;
}

final _quantity = NumberFormat.compact(locale: 'en_US')..significantDigits = 3;

/// 绘制代理接收已算好的指标，负责坐标、实时价格线、十字光标和回到最新。
class TerminalChartDelegate extends KLineDefaultDelegateImpl<ChartCandle> {
  TerminalChartDelegate({
    required this.english,
    required this.interval,
    required this.priceLines,
    required this.accountLines,
    required this.latest,
    required this.lineMode,
  }) : super(
         adapter: const ChartCandleAdapter(),
         mainIndicators: mainChartIndicators,
         secondaryIndicators: secondaryChartIndicators,
       );

  final bool english, lineMode;
  final String interval;
  final List<double> priceLines;
  final List<ChartOverlayLine> accountLines;
  final ChartCandle? latest;

  late final double _priceAxisWidth = _axisWidth(latest?.close ?? 0);

  // 每次绘图前先建立布局节点，同时计算后续绘制共用的纵轴范围。
  late double _low, _high, _step;
  double _y(double price, CandleChartContext context) =>
      context.layout.contentPadding.top +
      (_high - price) /
          (_high - _low) *
          context.layout.contentHeightForMainChart();

  /// 在实际价格轴左侧生成可见节点，并计算可见数据与实时价格共同覆盖的纵轴范围。
  @override
  List<CandleLayoutNode> getLayoutNodes(
    CandleChartContext context,
    List<ChartCandle> dataSource,
  ) {
    final width = context.viewportSize.width - _priceAxisWidth;
    final start = context.visibleRange.start;
    final end = ((context.controller.scrollOffset + width) / context.itemExtent)
        .ceil()
        .clamp(start + 1, dataSource.length);
    final bars = dataSource.getRange(start, end);
    final active = mainIndicators!.where(
      (i) => context.controller.activeIndicatorIds.contains(i.id),
    );
    // 历史视图也纳入实时收盘价，使实时价格线始终落在可见纵轴范围内。
    _low = _high = dataSource.last.close;
    for (final bar in bars) {
      _low = math.min(_low, lineMode ? bar.close : bar.low);
      _high = math.max(_high, lineMode ? bar.close : bar.high);
      for (final indicator in active) {
        for (final series in indicator.series) {
          final value = bar.indicators[series.id];
          if (value != null) {
            _low = math.min(_low, value);
            _high = math.max(_high, value);
          }
        }
      }
    }
    final margin = _high == _low
        ? math.max(_high.abs() * .001, 3e-8)
        : (_high - _low) * .035;
    _high += margin;
    _low = math.max(0, _low - margin);
    // 以约五格为目标，从 1、2、2.5、5、10 倍数量级选择刻度步长。
    final target = math.max((_high - _low) / 5, 1e-8);
    final unit = math
        .pow(10, (math.log(target) / math.ln10).floor())
        .toDouble();
    _step =
        [
          1,
          2,
          if (unit >= 1e-7) 2.5,
          5,
          10,
        ].firstWhere((n) => n * unit >= target, orElse: () => 10) *
        unit;
    return [
      for (var i = start; i < end; i++)
        KLineDefaultLayoutNode(
          index: i,
          item: dataSource[i],
          frame: Rect.fromLTWH(
            i * context.itemExtent,
            0,
            context.itemExtent,
            context.viewportSize.height,
          ),
          centerX: (i + .5) * context.itemExtent,
          bodyWidth: context.layout.scaledCandleWidth(context.controller.scale),
          highY: _y(dataSource[i].high, context),
          lowY: _y(dataSource[i].low, context),
          openY: _y(dataSource[i].open, context),
          closeY: _y(dataSource[i].close, context),
          candleColor: dataSource[i].close >= dataSource[i].open
              ? context.theme.candleUpColor
              : context.theme.candleDownColor,
        ),
    ];
  }

  /// 主图指标复用价格纵轴，副图委托图表库按自己的取值范围绘制。
  @override
  void drawIndicator(
    Canvas canvas,
    Rect rect,
    CandleChartContext context,
    KLineIndicatorSpec<ChartCandle> indicator,
  ) {
    if (!mainIndicators!.contains(indicator)) {
      super.drawIndicator(canvas, rect, context, indicator);
      return;
    }
    for (final series in indicator.series) {
      _drawSeries(
        canvas,
        context,
        (b) => b.indicators[series.id],
        context.theme.indicatorColorAt(series.colorIndex),
      );
    }
  }

  /// 遇到空指标值时断开线段，避免把预热期和有效数据强行连起来。
  void _drawSeries(
    Canvas canvas,
    CandleChartContext context,
    double? Function(ChartCandle) valueOf,
    Color color,
  ) {
    final path = Path();
    var started = false;
    for (final node in context.layoutNodes) {
      final value = valueOf(node.item);
      if (value == null) {
        started = false;
        continue;
      }
      if (started) {
        path.lineTo(node.centerX, _y(value, context));
      } else {
        path.moveTo(node.centerX, _y(value, context));
        started = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..color = color,
    );
  }

  /// 分时模式画收盘价线，普通模式复用库的蜡烛绘制。
  @override
  void drawMainChart(Canvas canvas, Size size, CandleChartContext context) {
    if (!lineMode) {
      super.drawMainChart(canvas, size, context);
      return;
    }
    final rect = Rect.fromLTWH(
      0,
      context.layout.contentPadding.top,
      context.viewportSize.width - _priceAxisWidth,
      context.layout.contentHeightForMainChart(),
    );
    canvas.save();
    canvas.clipRect(
      kLineDefaultDrawableClipRect(
        rect,
        scrollOffset: context.controller.scrollOffset,
      ),
    );
    _drawSeries(canvas, context, (b) => b.close, AppColors.accent);
    for (final indicator in mainIndicators!.where(
      (i) => context.controller.activeIndicatorIds.contains(i.id),
    )) {
      drawIndicator(canvas, rect, context, indicator);
    }
    canvas.restore();
  }

  void _label(
    Canvas canvas,
    String text,
    Offset anchor, {
    Color color = AppColors.muted,
    double align = 1,
    bool badge = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = Offset(
      anchor.dx - painter.width * align,
      anchor.dy - painter.height / 2,
    );
    if (badge) {
      final rect = RRect.fromRectAndRadius(
        (offset & painter.size).inflate(3),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, Paint()..color = AppColors.canvas);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .7
          ..color = color,
      );
    }
    painter.paint(canvas, offset);
  }

  void _dash(Canvas canvas, Offset start, Offset end, Color color) {
    final distance = (end - start).distance;
    if (distance == 0) return;
    final delta = (end - start) / distance;
    final paint = Paint()
      ..color = color
      ..strokeWidth = .7;
    for (var i = 0.0; i < distance; i += 5) {
      canvas.drawLine(
        start + delta * i,
        start + delta * math.min(i + 3, distance),
        paint,
      );
    }
  }

  /// 固定层绘制刻度、极值、日期和实时价；账户线与手工线也在此换算价格坐标。
  @override
  void drawGrid(Canvas canvas, Size size, CandleChartContext context) {
    final nodes = context.layoutNodes;
    if (nodes.isEmpty) return;
    final width = size.width;
    final mainHeight = context.layout.mainChartHeight;
    final plotWidth = width - _priceAxisWidth;
    final grid = Paint()
      ..color = AppColors.border.withValues(alpha: .55)
      ..strokeWidth = .5;
    final last = latest!;
    final lastY = _y(last.close, context);
    final hasLast =
        lastY >= context.layout.contentPadding.top &&
        lastY <= mainHeight - context.layout.contentPadding.bottom;
    for (var n = (_low / _step).ceil(); n <= (_high / _step).floor(); n++) {
      final v = n * _step, y = _y(v, context);
      canvas.drawLine(Offset(0, y), Offset(width, y), grid);
      if (!hasLast || (lastY - y).abs() > 16) {
        _label(canvas, _price.format(v), Offset(width - 5, y));
      }
    }
    if (!lineMode) {
      final peak = nodes.reduce((a, b) => a.item.high >= b.item.high ? a : b);
      final trough = nodes.reduce((a, b) => a.item.low <= b.item.low ? a : b);
      for (final (node, value, delta) in [
        (peak, peak.item.high, -9.0),
        (trough, trough.item.low, 9.0),
      ]) {
        final x = node.centerX - context.controller.scrollOffset;
        if (x < 0 || x > plotWidth) continue;
        final right = x < plotWidth / 2;
        final end = x + (right ? 8 : -8);
        final y = _y(value, context);
        canvas.drawLine(
          Offset(x, y),
          Offset(end, y),
          grid..color = AppColors.muted,
        );
        _label(
          canvas,
          _price.format(value),
          Offset(end, y + delta),
          align: right ? 0 : 1,
          color: AppColors.text,
        );
      }
      grid.color = AppColors.border.withValues(alpha: .55);
    }
    final selected = context.selectedNode;
    final cursor = context.controller.selectionLocalPosition;
    if (selected != null && cursor != null) {
      final y = cursor.dy;
      if (y >= context.layout.contentPadding.top &&
          y <= mainHeight - context.layout.contentPadding.bottom) {
        final price =
            _high -
            (y - context.layout.contentPadding.top) /
                context.layout.contentHeightForMainChart() *
                (_high - _low);
        _label(
          canvas,
          _price.format(double.parse(price.toStringAsPrecision(5))),
          Offset(width - 7, y),
          color: AppColors.text,
          badge: true,
        );
      }
    }
    final intraday = interval.endsWith('m') || interval.endsWith('h');
    final format = DateFormat(intraday ? 'MM-dd HH:mm' : 'yy-MM-dd');
    double previousRight = -1;
    for (final node in nodes) {
      final x = node.centerX - context.controller.scrollOffset;
      final spacing = intraday ? 72.0 : 62.0;
      final stride = (spacing / context.itemExtent).ceil();
      if (node.index % stride != 0 || x < 0 || x > plotWidth) continue;
      final left = (x - spacing / 2).clamp(3.0, width - spacing);
      if (left < previousRight) continue;
      _label(
        canvas,
        format.format(DateTime.fromMillisecondsSinceEpoch(node.item.time)),
        Offset(left, mainHeight - 10),
        align: 0,
      );
      previousRight = left + spacing - 5;
    }
    canvas.drawLine(
      Offset(0, mainHeight - 20),
      Offset(width, mainHeight - 20),
      grid,
    );
    if (selected != null) {
      final x = (selected.centerX - context.controller.scrollOffset).clamp(
        43.0,
        width - 43,
      );
      _label(
        canvas,
        adapter.dateLabel(selected.item),
        Offset(x, mainHeight - 10),
        align: .5,
        color: AppColors.text,
        badge: true,
      );
    }
    var top = mainHeight;
    for (final indicator in activeSecondaryIndicators(context)) {
      canvas.drawLine(Offset(0, top), Offset(width, top), grid);
      final height = indicatorHeight(context, indicator);
      if (indicator.id == 'volume') {
        final maximum = nodes.fold<double>(0, (max, node) {
          var value = math.max(max, node.item.volume);
          for (final s in indicator.series) {
            value = math.max(value, node.item.indicators[s.id] ?? 0);
          }
          return value;
        });
        final inset = context.layout.secondaryContentVerticalPadding;
        for (final fraction in [1.0, .5, 0.0]) {
          _label(
            canvas,
            _quantity.format(maximum * fraction),
            Offset(
              width - 5,
              top + inset + (height - 2 * inset) * (1 - fraction),
            ),
          );
        }
      }
      top += height;
    }
    if (hasLast) {
      // 最新蜡烛可见时从它开始延伸虚线，移出视口后从左边缘贯穿主图。
      final liveX =
          (context.itemCount - .5) * context.itemExtent -
          context.controller.scrollOffset;
      final x = liveX >= 0 && liveX <= plotWidth ? liveX : 0.0;
      _dash(
        canvas,
        Offset(x, lastY),
        Offset(width - 4, lastY),
        AppColors.muted,
      );
      _label(
        canvas,
        _price.format(last.close),
        Offset(width - 7, lastY),
        color: AppColors.text,
        badge: true,
      );
    }
    for (final (value, color, label) in [
      for (final p in priceLines) (p, AppColors.accent, _price.format(p)),
      for (final l in accountLines)
        (
          l.price,
          switch (l.kind) {
            ChartOverlayKind.order => AppColors.positive,
            ChartOverlayKind.protection => AppColors.negative,
            _ => AppColors.accent,
          },
          '${l.label} ${_price.format(l.price)}',
        ),
    ]) {
      if (value < _low || value > _high) continue;
      final y = _y(value, context);
      _dash(canvas, Offset(0, y), Offset(plotWidth, y), color);
      _label(canvas, label, Offset(width - 5, y), color: color);
    }
  }

  /// 滚动层使用内容坐标，横向位置最终由滚动容器偏移到视口。
  @override
  void drawChart(Canvas canvas, Size size, CandleChartContext context) {
    // 图表库同时把 chartPadding 用于滚动范围和裁剪范围。
    // 保留最新一根右侧留白，同时让历史蜡烛和成交量绘制到实际价格轴旁。
    final plot = CandleChartContext(
      controller: context.controller,
      layout: chartLayout(
        context.viewportSize.width,
        rightInset: _priceAxisWidth,
      ),
      theme: context.theme,
      viewportSize: context.viewportSize,
      itemCount: context.itemCount,
      itemExtent: context.itemExtent,
      contentWidth: context.contentWidth,
      visibleRange: context.visibleRange,
      layoutNodes: context.layoutNodes,
    );
    drawMainChart(canvas, size, plot);
    drawSecondaryCharts(canvas, size, plot);
    final selected = context.selectedNode;
    if (selected == null) return;
    final x = selected.centerX,
        y = context.controller.selectionLocalPosition!.dy;
    final left = context.controller.scrollOffset;
    _dash(
      canvas,
      Offset(x, context.layout.contentPadding.top),
      Offset(x, size.height),
      AppColors.muted,
    );
    _dash(
      canvas,
      Offset(left, y),
      Offset(left + context.viewportSize.width, y),
      AppColors.muted,
    );
  }

  @override
  // 图例和点击层覆盖整张图；首次点击选中，再次点击清除，长按拖动移动选中点。
  Widget buildOverlayView(
    BuildContext context,
    CandleChartContext chartContext,
  ) {
    final bar =
        chartContext.selectedNode?.item ?? chartContext.layoutNodes.last.item;
    var paneTop = chartContext.layout.mainChartHeight;
    Widget legend(
      double top,
      Iterable<KLineIndicatorSpec<ChartCandle>> specs,
    ) => Positioned(
      top: top + 2,
      left: 6,
      right: 4,
      child: IgnorePointer(
        child: Text.rich(
          TextSpan(
            children: [
              for (final spec in specs) ...[
                if (spec.id == 'volume')
                  TextSpan(text: 'VOL ${_quantity.format(bar.volume)}   '),
                for (final line in spec.series)
                  if (bar.indicators[line.id] case final value?)
                    TextSpan(
                      text:
                          '${line.label} ${spec.id == "volume" ? _quantity.format(value) : _price.format(double.parse(value.toStringAsPrecision(5)))}   ',
                      style: TextStyle(
                        color: chartContext.theme.indicatorColorAt(
                          line.colorIndex,
                        ),
                      ),
                    ),
              ],
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
        ),
      ),
    );
    final labels = <Widget>[
      legend(
        0,
        mainIndicators!.where(
          (i) => chartContext.controller.activeIndicatorIds.contains(i.id),
        ),
      ),
    ];
    for (final indicator in activeSecondaryIndicators(chartContext)) {
      labels.add(legend(paneTop, [indicator]));
      paneTop += indicatorHeight(chartContext, indicator);
    }
    final controller = chartContext.controller;
    void select(Offset point, {bool toggle = false}) {
      if (toggle && controller.selectedIndex != null) {
        controller.clearSelection();
        return;
      }
      final nodes = chartContext.layoutNodes;
      final index =
          ((point.dx + controller.scrollOffset) / chartContext.itemExtent)
              .floor()
              .clamp(nodes.first.index, nodes.last.index);
      controller.selectIndex(
        index,
        localPosition: point,
        contentPosition: Offset(
          (index + .5) * chartContext.itemExtent,
          point.dy,
        ),
      );
    }

    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (e) => select(e.localPosition, toggle: true),
            onLongPressStart: (e) => select(e.localPosition),
            onLongPressMoveUpdate: (e) => select(e.localPosition),
            onHorizontalDragUpdate: controller.selectedIndex == null
                ? null
                : (e) => select(e.localPosition),
            child: IgnorePointer(child: Stack(children: labels)),
          ),
          if (chartContext.contentWidth -
                      chartContext.viewportSize.width -
                      controller.scrollOffset >
                  1 ||
              (controller.scale - 1).abs() > .001)
            Positioned(
              right: _priceAxisWidth,
              bottom: 2,
              child: IconButton(
                tooltip: english ? 'Back to latest' : '回到最新',
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surface,
                  foregroundColor: AppColors.text,
                  minimumSize: const Size(36, 36),
                ),
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
                onPressed: () {
                  controller.clearSelection();
                  // 恢复默认蜡烛宽度，并按时间升序数据的最后一个索引回到最新。
                  controller.setScale(1);
                  controller.scrollToIndex(
                    chartContext.itemCount - 1,
                    animated: false,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  // 选中蜡烛的浮层显示开高低收和时间，IgnorePointer 让手势继续交给图表。
  Widget buildSelectionView(
    BuildContext context,
    CandleChartContext chartContext,
    CandleLayoutNode selectedNode,
  ) {
    final b = selectedNode.item;
    final x = selectedNode.centerX - chartContext.controller.scrollOffset;
    return Positioned(
      top: 24,
      left: x > chartContext.viewportSize.width / 2 ? 8 : null,
      right: x > chartContext.viewportSize.width / 2 ? null : 8,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.panel,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  adapter.dateLabel(b),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                for (final (key, value) in [
                  (english ? 'Open' : '开盘', _price.format(b.open)),
                  (english ? 'High' : '最高', _price.format(b.high)),
                  (english ? 'Low' : '最低', _price.format(b.low)),
                  (english ? 'Close' : '收盘', _price.format(b.close)),
                  (english ? 'Volume' : '成交量', _price.format(b.volume)),
                ])
                  Text(
                    '$key  $value',
                    style: const TextStyle(fontSize: 11, color: AppColors.text),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
