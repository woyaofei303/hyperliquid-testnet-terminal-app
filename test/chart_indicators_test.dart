// 蜡烛合并和指标适配的离线测试：检查乱序覆盖、27 个选项以及 MA/SMA 的样例值；并非逐项证明全部指标数值一致。

import 'package:flutter_test/flutter_test.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:hyperliquid_testnet_terminal/src/chart/chart_candle.dart';

void main() {
  test(
    'BTC snapshot and 1m pushes merge across rollover without regression',
    () {
      final [first, update, next, settled] = [
        Candle.fromJson({
          "t": 1793795940000,
          "T": 1793795999999,
          "s": "BTC",
          "i": "1m",
          "o": "78817.0",
          "c": "79852.0",
          "h": "79852.0",
          "l": "78817.0",
          "v": "0.12278",
          "n": 57,
        }),
        Candle.fromJson({
          "t": 1793795940000,
          "T": 1793795999999,
          "s": "BTC",
          "i": "1m",
          "o": "78817.0",
          "c": "79676.0",
          "h": "79852.0",
          "l": "78817.0",
          "v": "0.12313",
          "n": 58,
        }),
        Candle.fromJson({
          "t": 1793796000000,
          "T": 1793796059999,
          "s": "BTC",
          "i": "1m",
          "o": "79836.0",
          "c": "79836.0",
          "h": "79836.0",
          "l": "79836.0",
          "v": "0.00015",
          "n": 1,
        }),
        Candle.fromJson({
          "t": 1793795940000,
          "T": 1793795999999,
          "s": "BTC",
          "i": "1m",
          "o": "78817.0",
          "c": "79836.0",
          "h": "79860.0",
          "l": "78817.0",
          "v": "0.13773",
          "n": 102,
        }),
      ];
      final bars = mergeCandles([first], [update, next, first, next]);
      expect(bars, [update, next]);
      expect(mergeCandles(bars, [first]), [update, next]);
      expect(mergeCandles(bars, [settled]), [settled, next]);
    },
  );
  test('adapts candles and exposes the 27 web indicator choices', () {
    final candles = [
      for (var i = 0; i < 60; i++)
        Candle(
          startTime: i * 60000,
          endTime: (i + 1) * 60000,
          open: 99 + i.toDouble(),
          high: 102 + i.toDouble(),
          low: 98 + i.toDouble(),
          close: 100 + i.toDouble(),
          volume: 10 + i.toDouble(),
          numTrades: 1,
        ),
    ];
    final adapted = ChartCandle.fromCandles(candles);
    final labels = allChartIndicators
        .map((indicator) => indicator.label)
        .toSet();

    expect(adapted, hasLength(60));
    expect(adapted[4].indicators['ma5'], 102);
    expect(adapted.last.indicators['sma'], 154.5);
    expect(labels, hasLength(27));
    expect(
      labels,
      containsAll([
        'MA',
        'EMA',
        'SMA',
        'BBI',
        'BOLL',
        'DMA',
        'SAR',
        'AVP',
        'AO',
        'BIAS',
        'BRAR',
        'CCI',
        'CR',
        'DMI',
        'EMV',
        'MTM',
        'MACD',
        'OBV',
        'PVT',
        'PSY',
        'ROC',
        'RSI',
        'KDJ',
        'TRIX',
        'VOL',
        'VR',
        'WR',
      ]),
    );
  });
}
