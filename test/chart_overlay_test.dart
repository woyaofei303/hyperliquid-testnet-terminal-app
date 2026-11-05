// 用模拟账户对象验证按币种筛选仓位、委托和保护线，避免其他市场的价格混入当前图表。

import 'package:flutter_test/flutter_test.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:hyperliquid_testnet_terminal/src/chart/chart_overlay.dart';

void main() {
  test(
    'chart overlays separate position, open order and protection prices',
    () {
      final lines = buildChartAccountLines(
        coin: 'BTC',
        positions: const [
          {
            'position': {'coin': 'BTC', 'szi': '0.02', 'entryPx': '58000'},
          },
          {
            'position': {'coin': 'ETH', 'szi': '1', 'entryPx': '2000'},
          },
          {
            'position': {'coin': 'BTC', 'szi': '0', 'entryPx': '59000'},
          },
        ],
        orders: const [
          OpenOrder(
            coin: 'BTC',
            side: 'B',
            limitPx: '57000',
            sz: '0.02',
            oid: 1,
            timestamp: 1,
          ),
          OpenOrder(
            coin: 'BTC',
            side: 'A',
            limitPx: '54000',
            sz: '0.02',
            oid: 2,
            timestamp: 2,
            isTrigger: true,
            triggerPx: '55000',
            reduceOnly: true,
          ),
          OpenOrder(
            coin: 'ETH',
            side: 'B',
            limitPx: '1900',
            sz: '1',
            oid: 3,
            timestamp: 3,
          ),
        ],
        english: false,
      );

      expect(lines.map((line) => line.price), [58000, 57000, 55000]);
      expect(lines.map((line) => line.kind), [
        ChartOverlayKind.position,
        ChartOverlayKind.order,
        ChartOverlayKind.protection,
      ]);
    },
  );
}
