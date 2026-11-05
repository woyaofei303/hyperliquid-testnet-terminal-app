// 将账户仓位和委托转换为只读价格线。按 API 币种名过滤，避免叠加到其他市场。

import 'package:hyperliquid_dart/hyperliquid_dart.dart';

enum ChartOverlayKind { position, order, protection }

/// 一条只读账户线，label 已按当前页面语言生成。
class ChartOverlayLine {
  const ChartOverlayLine({
    required this.price,
    required this.kind,
    required this.label,
  });

  final double price;
  final ChartOverlayKind kind;
  final String label;
}

/// 仓位取非零仓位的开仓均价；触发委托取触发价；触发且只减仓的订单归为保护线。
List<ChartOverlayLine> buildChartAccountLines({
  required String coin,
  required List<dynamic> positions,
  required List<OpenOrder> orders,
  required bool english,
}) {
  final lines = <ChartOverlayLine>[];
  final targetCoin = coin.toUpperCase();

  for (final entry in positions) {
    if (entry is! Map) continue;
    final position = entry['position'];
    if (position is! Map) continue;
    if (position['coin']?.toString().toUpperCase() != targetCoin) continue;
    final size = double.tryParse(position['szi']?.toString() ?? '');
    if (size == null || !size.isFinite || size == 0) continue;
    final price = _validPrice(position['entryPx']);
    if (price != null) {
      lines.add(
        ChartOverlayLine(
          price: price,
          kind: ChartOverlayKind.position,
          label: english ? 'Position' : '仓位',
        ),
      );
    }
  }

  for (final order in orders) {
    if (order.coin.toUpperCase() != targetCoin) continue;
    final protection = order.isTrigger == true && order.reduceOnly == true;
    final price = _validPrice(
      order.isTrigger == true ? order.triggerPx : order.limitPx,
    );
    if (price != null) {
      lines.add(
        ChartOverlayLine(
          price: price,
          kind: protection
              ? ChartOverlayKind.protection
              : ChartOverlayKind.order,
          label: protection
              ? (english ? 'Protection' : '保护单')
              : (english ? 'Order' : '委托'),
        ),
      );
    }
  }

  return lines;
}

double? _validPrice(Object? value) {
  final price = double.tryParse(value?.toString() ?? '');
  return price != null && price.isFinite && price > 0 ? price : null;
}
