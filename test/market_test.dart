// 市场模型的纯计算测试：前日价格有效才计算涨跌幅，缺失数据不伪装成零涨跌。

import 'package:flutter_test/flutter_test.dart';
import 'package:hyperliquid_testnet_terminal/src/market/market.dart';

void main() {
  test('market change is calculated from the previous day price', () {
    const market = MarketTicker(
      coin: 'BTC',
      kind: MarketKind.perpetual,
      price: 110,
      previousPrice: 100,
      dayVolume: 1000000,
      sizeDecimals: 5,
    );

    expect(market.changePercent, 10);
  });

  test('market change remains absent without a valid previous price', () {
    const market = MarketTicker(
      coin: 'BTC',
      kind: MarketKind.perpetual,
      price: 100,
      previousPrice: 0,
      dayVolume: 1000000,
      sizeDecimals: 5,
    );

    expect(market.changePercent, isNull);
  });
}
