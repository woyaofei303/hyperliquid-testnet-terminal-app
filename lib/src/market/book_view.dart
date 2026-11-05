// 盘口与深度视图。先过滤无效档位并计算累计量，再生成数值行或累计深度图。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:intl/intl.dart';

import '../app/theme.dart';
import 'market.dart';

typedef _Level = ({String quote, double price, double size, double total});

/// 盘口按买价降序、卖价升序排列，并以基础资产数量逐档累计。
List<_Level> _side(List<L2Level> levels, {required bool bids}) {
  final raw =
      [
            for (final level in levels)
              (
                quote: level.price,
                price: double.tryParse(level.price) ?? 0.0,
                size: double.tryParse(level.size) ?? 0.0,
              ),
          ]
          .where(
            (v) =>
                v.price.isFinite &&
                v.price > 0 &&
                v.size.isFinite &&
                v.size > 0,
          )
          .toList()
        ..sort(
          (a, b) =>
              bids ? b.price.compareTo(a.price) : a.price.compareTo(b.price),
        );
  var total = 0.0;
  return [
    for (final v in raw)
      (quote: v.quote, price: v.price, size: v.size, total: total += v.size),
  ];
}

final _number = NumberFormat('#,##0.########');
const _digits = TextStyle(
  fontSize: 13,
  fontFeatures: [FontFeature.tabularFigures()],
);
const _legend = TextStyle(color: AppColors.muted, fontSize: 12);

/// 展示订单簿或深度图；onPrice 只回填表单，点盘口不会直接提交订单。
class BookView extends StatelessWidget {
  const BookView({
    super.key,
    required this.book,
    required this.depth,
    required this.failed,
    required this.english,
    required this.market,
    this.onPrice,
    this.onRetry,
    this.compact = false,
  });
  final L2Book? book;
  final bool depth, english, failed, compact;
  final MarketTicker market;
  final ValueChanged<String>? onPrice;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final bids = _side(book?.bids ?? [], bids: true);
    final asks = _side(book?.asks ?? [], bids: false);
    final base = market.kind == MarketKind.outcome
        ? (english ? 'shares' : '份')
        : market.base ?? market.coin;
    final maxTotal = math.max(
      bids.lastOrNull?.total ?? 0.0,
      asks.lastOrNull?.total ?? 0.0,
    );
    // 颜色条使用可见五档的累计量归一化，让两边的深浅具有同一比较基准。
    final visibleMax = math.max(
      bids.take(5).lastOrNull?.total ?? 0.0,
      asks.take(5).lastOrNull?.total ?? 0.0,
    );
    final spread = bids.isEmpty || asks.isEmpty
        ? '—'
        : _number.format(asks.first.price - bids.first.price);
    return Material(
      color: compact ? AppColors.canvas : AppColors.panel,
      borderRadius: BorderRadius.circular(compact ? 0 : 12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(compact ? 0 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (maxTotal == 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: failed && onRetry != null
                    ? TextButton(
                        onPressed: onRetry,
                        child: Text(english ? 'Retry book' : '重试盘口'),
                      )
                    : Text(
                        failed
                            ? (english
                                  ? 'Book unavailable · tap refresh to retry'
                                  : '盘口暂不可用，可点刷新重试')
                            : book == null
                            ? (english ? 'Loading book…' : '正在读取盘口…')
                            : (english ? 'No resting orders' : '暂无挂单'),
                        textAlign: TextAlign.center,
                      ),
              )
            else if (depth) ...[
              Text(
                '${english ? 'Cumulative size' : '累计挂单量'} ($base)',
                style: _legend,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${english ? 'Bids' : '买盘'}  ${_number.format(bids.lastOrNull?.total ?? 0)}',
                    style: _digits.copyWith(color: AppColors.positive),
                  ),
                  Text(
                    '${english ? 'Asks' : '卖盘'}  ${_number.format(asks.lastOrNull?.total ?? 0)}',
                    style: _digits.copyWith(color: AppColors.negative),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 174,
                child: CustomPaint(
                  painter: _DepthPainter(bids, asks, maxTotal),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _number.format(bids.lastOrNull?.price ?? asks.first.price),
                    style: _legend,
                  ),
                  Text(
                    '${english ? 'Price' : '价格'} (${market.quote})',
                    style: _legend,
                  ),
                  Text(
                    _number.format(asks.lastOrNull?.price ?? bids.first.price),
                    style: _legend,
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      compact
                          ? "${english ? 'Price' : '价格'}\n(${market.quote})"
                          : "${english ? 'Price' : '价格'} (${market.quote})",
                      style: _legend,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      compact
                          ? "${english ? 'Size' : '数量'}\n($base)"
                          : "${english ? 'Size' : '数量'} ($base)",
                      textAlign: TextAlign.end,
                      style: _legend,
                    ),
                  ),
                  if (!compact)
                    Expanded(
                      child: Text(
                        english ? 'Cumulative' : '累计',
                        textAlign: TextAlign.end,
                        style: _legend,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (final level in asks.take(5).toList().reversed)
                _levelRow(level, AppColors.negative, visibleMax),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${english ? 'Spread' : '买卖价差'}  $spread ${market.quote}',
                  style: _legend,
                ),
              ),
              for (final level in bids.take(5))
                _levelRow(level, AppColors.positive, visibleMax),
              if (onPrice != null && !compact)
                Text(
                  english ? 'Tap a price to fill a limit order' : '点选价格可填入限价单',
                  style: _legend,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _levelRow(_Level l, Color color, double max) => InkWell(
    onTap: onPrice == null ? null : () => onPrice!(l.quote),
    child: SizedBox(
      height: compact ? 25 : 32,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          FractionallySizedBox(
            widthFactor: (l.total / max).clamp(0, 1),
            heightFactor: .85,
            child: ColoredBox(color: color.withValues(alpha: .1)),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  _number.format(l.price),
                  style: _digits.copyWith(color: color),
                ),
              ),
              Expanded(
                child: Text(
                  _number.format(l.size),
                  textAlign: TextAlign.end,
                  style: _digits,
                ),
              ),
              if (!compact)
                Expanded(
                  child: Text(
                    _number.format(l.total),
                    textAlign: TextAlign.end,
                    style: _digits.copyWith(color: AppColors.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 把价格映射到横轴、累计挂单量映射到纵轴，并填充买卖两侧区域。
class _DepthPainter extends CustomPainter {
  const _DepthPainter(this.bids, this.asks, this.maxTotal);
  final List<_Level> bids, asks;
  final double maxTotal;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = bids.lastOrNull?.price ?? asks.first.price;
    final hi = asks.lastOrNull?.price ?? bids.first.price;
    double x(double px) =>
        hi <= lo ? size.width / 2 : (px - lo) / (hi - lo) * size.width;
    final grid = Paint()..color = AppColors.border;
    for (var i = 1; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    void draw(List<_Level> levels, Color color) {
      if (levels.isEmpty) return;
      var y = size.height;
      final path = Path()..moveTo(x(levels.first.price), y);
      for (final level in levels) {
        final px = x(level.price);
        path.lineTo(px, y);
        y = size.height * (1 - level.total / maxTotal);
        path.lineTo(px, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      path.lineTo(x(levels.last.price), size.height);
      path.close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: .17));
    }

    draw(bids, AppColors.positive);
    draw(asks, AppColors.negative);
  }

  @override
  bool shouldRepaint(_DepthPainter oldDelegate) =>
      bids != oldDelegate.bids || asks != oldDelegate.asks;
}
