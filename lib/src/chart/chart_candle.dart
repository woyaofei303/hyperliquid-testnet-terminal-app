// 蜡烛数据合并、指标计算和 kline_flutter 适配。输入按时间升序，价格绘图使用 double。

import 'dart:math' as math;

import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:kline_flutter/kline_flutter.dart';

/// 返回异常原因，正常为 null；秒/毫秒、NaN 或倒置价格不能传入指标计算。
String? candleIssue(Candle bar) {
  if (![
    bar.open,
    bar.high,
    bar.low,
    bar.close,
    bar.volume,
  ].every((v) => v.isFinite)) {
    return 'non-finite';
  }
  if (bar.startTime < 0 || bar.endTime < bar.startTime) return 'time';
  if (bar.low <= 0 ||
      bar.high < bar.low ||
      bar.open < bar.low ||
      bar.open > bar.high ||
      bar.close < bar.low ||
      bar.close > bar.high) {
    return 'ohlc';
  }
  if (bar.volume < 0 || bar.numTrades < 0) return 'volume';
  return null;
}

// 快照和推送都携带同一周期桶的累计量，不能把推送成交量再次累加。
bool newerCandle(Candle incoming, Candle current) =>
    incoming.numTrades > current.numTrades ||
    (incoming.numTrades == current.numTrades &&
        incoming.volume > current.volume);

/// 以周期起始时间去重，只采纳更新的累计数据，排序后最多保留最近 500 根。
List<Candle> mergeCandles(Iterable<Candle> current, Iterable<Candle> updates) {
  final buckets = {for (final bar in current) bar.startTime: bar};
  for (final bar in updates) {
    final old = buckets[bar.startTime];
    if (old == null || newerCandle(bar, old)) buckets[bar.startTime] = bar;
  }
  final bars = buckets.values.toList()
    ..sort((a, b) => a.startTime.compareTo(b.startTime));
  return bars.length > 500 ? bars.sublist(bars.length - 500) : bars;
}

/// 保存交易所原始蜡烛和各条指标线的数值，供绘图适配器按名称读取。
class ChartCandle {
  const ChartCandle(this.source, this.indicators);

  final Candle source;
  final Map<String, double?> indicators;

  double get open => source.open;
  double get high => source.high;
  double get low => source.low;
  double get close => source.close;
  double get volume => source.volume;
  int get time => source.startTime;

  /// 从头累计指标。窗口不足时部分指标返回 null，绘图层据此留空而非补零。
  static List<ChartCandle> fromCandles(List<Candle> candles) {
    final result = <ChartCandle>[];
    final close = <double>[];
    final high = <double>[];
    final low = <double>[];
    final open = <double>[];
    final volume = <double>[];
    final typical = <double>[];
    final medianValues = <double>[];
    final ema12 = <double>[];
    final ema26 = <double>[];
    final emaTrixFirst = <double>[];
    final emaTrixSecond = <double>[];
    final emaTrixThird = <double>[];
    final trixSignal = <double>[];
    final macdSignal = <double>[];
    final emvValues = <double>[];
    final dxValues = <double>[];
    var obv = 0.0;
    var pvt = 0.0;
    var avpNumerator = 0.0;
    var avpVolume = 0.0;
    var sar = 0.0;
    var sarExtreme = 0.0;
    var sarAcceleration = 0.02;
    var sarRising = true;

    for (var i = 0; i < candles.length; i++) {
      final candle = candles[i];
      close.add(candle.close);
      high.add(candle.high);
      low.add(candle.low);
      open.add(candle.open);
      volume.add(candle.volume);
      typical.add((candle.high + candle.low + candle.close) / 3);
      medianValues.add((candle.high + candle.low) / 2);
      final previousClose = i == 0 ? candle.close : close[i - 1];
      final median = (candle.high + candle.low) / 2;
      // EMA 逐步递推，DIF 为两条 EMA 的差，DEA 为 DIF 的平滑值。
      final current12 = _ema(ema12, candle.close, 12);
      final current26 = _ema(ema26, candle.close, 26);
      ema12.add(current12);
      ema26.add(current26);
      final dif = current12 - current26;
      final dea = _ema(macdSignal, dif, 9);
      macdSignal.add(dea);
      // SAR 使用趋势方向、极值和加速因子跨蜡烛递推，反转时重置加速因子。
      if (i == 0) {
        sar = candle.low;
        sarExtreme = candle.high;
      } else {
        sar += sarAcceleration * (sarExtreme - sar);
        if (sarRising) {
          sar = math.min(sar, low[i - 1]);
          if (i > 1) sar = math.min(sar, low[i - 2]);
          if (candle.low < sar) {
            sarRising = false;
            sar = sarExtreme;
            sarExtreme = candle.low;
            sarAcceleration = 0.02;
          } else if (candle.high > sarExtreme) {
            sarExtreme = candle.high;
            sarAcceleration = math.min(0.2, sarAcceleration + 0.02);
          }
        } else {
          sar = math.max(sar, high[i - 1]);
          if (i > 1) sar = math.max(sar, high[i - 2]);
          if (candle.high > sar) {
            sarRising = true;
            sar = sarExtreme;
            sarExtreme = candle.high;
            sarAcceleration = 0.02;
          } else if (candle.low < sarExtreme) {
            sarExtreme = candle.low;
            sarAcceleration = math.min(0.2, sarAcceleration + 0.02);
          }
        }
      }
      final trixFirst = _ema(emaTrixFirst, current12, 12);
      final trixSecond = _ema(emaTrixSecond, trixFirst, 12);
      final trixThird = _ema(emaTrixThird, trixSecond, 12);
      emaTrixFirst.add(trixFirst);
      emaTrixSecond.add(trixSecond);
      emaTrixThird.add(trixThird);
      final trix = i == 0 || emaTrixThird[i - 1] == 0
          ? null
          : (trixThird - emaTrixThird[i - 1]) / emaTrixThird[i - 1] * 100;
      final signal = trix == null ? null : _ema(trixSignal, trix, 9);
      if (trix != null) trixSignal.add(signal!);
      obv += i == 0
          ? 0
          : candle.close > previousClose
          ? candle.volume
          : candle.close < previousClose
          ? -candle.volume
          : 0;
      pvt += i == 0 || previousClose == 0
          ? 0
          : candle.volume * (candle.close - previousClose) / previousClose;
      avpNumerator += typical[i] * candle.volume;
      avpVolume += candle.volume;

      final ma = <int, double?>{
        for (final n in [3, 5, 6, 10, 12, 20, 24, 30, 50, 34, 60])
          n: _average(close, n),
      };
      final volumeMa5 = _average(volume, 5);
      final volumeMa10 = _average(volume, 10);
      final sd20 = _std(close, 20);
      final high14 = _max(high, 14);
      final low14 = _min(low, 14);
      final recent14 = _window(typical, 14);
      final typicalAverage = _average(typical, 14);
      final deviation = recent14 == null || typicalAverage == null
          ? null
          : recent14
                    .map((value) => (value - typicalAverage).abs())
                    .reduce((a, b) => a + b) /
                recent14.length;
      final rsv = high14 == null || low14 == null || high14 == low14
          ? null
          : (candle.close - low14) / (high14 - low14) * 100;
      // 当前递推读取 kdjK/kdjD，而输出字段是 k/d，数值一致性仍需专门校验。
      final kPrevious = i == 0 ? 50.0 : (result.last.indicators['kdjK'] ?? 50);
      final dPrevious = i == 0 ? 50.0 : (result.last.indicators['kdjD'] ?? 50);
      final k = rsv == null ? null : (2 * kPrevious + rsv) / 3;
      final d = k == null ? null : (2 * dPrevious + k) / 3;
      final changes = i == 0 ? null : close[i] - close[i - 1];
      final upMoves = _sumRange(i, 14, (j) => math.max(0, high[j] - open[j]));
      final downMoves = _sumRange(i, 14, (j) => math.max(0, open[j] - low[j]));
      final br =
          _sumRange(
            i,
            26,
            (j) => math.max(0, high[j] - (j == 0 ? open[j] : close[j - 1])),
          ) /
          math.max(
            1e-12,
            _sumRange(
              i,
              26,
              (j) => math.max(0, (j == 0 ? open[j] : close[j - 1]) - low[j]),
            ),
          ) *
          100;
      final crMid = (high[i] + low[i]) / 2;
      final cr =
          _sumRange(
            i,
            26,
            (j) => math.max(
              0,
              high[j] - (j == 0 ? crMid : (high[j - 1] + low[j - 1]) / 2),
            ),
          ) /
          math.max(
            1e-12,
            _sumRange(
              i,
              26,
              (j) => math.max(
                0,
                (j == 0 ? crMid : (high[j - 1] + low[j - 1]) / 2) - low[j],
              ),
            ),
          ) *
          100;
      final trueRange = math.max(
        candle.high - candle.low,
        math.max(
          (candle.high - previousClose).abs(),
          (candle.low - previousClose).abs(),
        ),
      );
      final plusDm = i == 0
          ? 0.0
          : math.max(0, candle.high - high[i - 1]) >
                math.max(0, low[i - 1] - candle.low)
          ? math.max(0, candle.high - high[i - 1]).toDouble()
          : 0.0;
      final minusDm = i == 0
          ? 0.0
          : math.max(0, low[i - 1] - candle.low) >
                math.max(0, candle.high - high[i - 1])
          ? math.max(0, low[i - 1] - candle.low).toDouble()
          : 0.0;
      final tr14 = _sumRange(
        i,
        14,
        (j) => math.max(
          high[j] - low[j],
          math.max(
            (high[j] - (j == 0 ? open[j] : close[j - 1])).abs(),
            (low[j] - (j == 0 ? open[j] : close[j - 1])).abs(),
          ),
        ),
      );
      final plus14 = _sumRange(
        i,
        14,
        (j) => j == 0
            ? 0
            : math.max(0, high[j] - high[j - 1]) >
                  math.max(0, low[j - 1] - low[j])
            ? math.max(0, high[j] - high[j - 1])
            : 0,
      );
      final minus14 = _sumRange(
        i,
        14,
        (j) => j == 0
            ? 0
            : math.max(0, low[j - 1] - low[j]) >
                  math.max(0, high[j] - high[j - 1])
            ? math.max(0, low[j - 1] - low[j])
            : 0,
      );
      final plusDi = tr14 == 0 ? null : plus14 / tr14 * 100;
      final minusDi = tr14 == 0 ? null : minus14 / tr14 * 100;
      if (plusDi != null && minusDi != null && plusDi + minusDi != 0) {
        dxValues.add((plusDi - minusDi).abs() / (plusDi + minusDi) * 100);
      }
      final emvWindow = i == 0
          ? null
          : (median - (high[i - 1] + low[i - 1]) / 2) *
                (candle.high - candle.low) /
                math.max(1e-12, candle.volume);
      if (emvWindow != null) emvValues.add(emvWindow);
      final vrUp = _sumRange(
        i,
        26,
        (j) => j == 0 || close[j] < close[j - 1] ? 0 : volume[j],
      );
      final vrDown = _sumRange(
        i,
        26,
        (j) => j == 0 || close[j] > close[j - 1] ? 0 : volume[j],
      );
      final wrHigh = _max(high, 14);
      final wrLow = _min(low, 14);
      final rsi = <int, double?>{
        for (final n in [6, 12, 24]) n: _rsi(close, n),
      };
      // 这里的键必须与下方指标定义中的 series.id 一致，适配器按键取值。
      result.add(
        ChartCandle(candle, {
          'ma5': ma[5],
          'ma10': ma[10],
          'ma30': ma[30],
          'ma60': ma[60],
          'ema5': _emaValue(close, 5),
          'ema10': _emaValue(close, 10),
          'ema30': _emaValue(close, 30),
          'bollUpper': ma[20] == null || sd20 == null
              ? null
              : ma[20]! + 2 * sd20,
          'bollMiddle': ma[20],
          'bollLower': ma[20] == null || sd20 == null
              ? null
              : ma[20]! - 2 * sd20,
          'volumeMA5': volumeMa5,
          'volumeMA10': volumeMa10,
          'volumeMA20': _average(volume, 20),
          'dif': dif,
          'dea': dea,
          'macd': (dif - dea) * 2,
          'k': k,
          'd': d,
          'j': k == null || d == null ? null : 3 * k - 2 * d,
          'rsi6': rsi[6],
          'rsi12': rsi[12],
          'rsi24': rsi[24],
          'wr6': _wr(high, low, close, 6),
          'wr10': _wr(high, low, close, 10),
          'wr14': _wr(high, low, close, 14),
          'sma': ma[10],
          'bbi': [ma[3], ma[6], ma[12], ma[24]].contains(null)
              ? null
              : [ma[3]!, ma[6]!, ma[12]!, ma[24]!].reduce((a, b) => a + b) / 4,
          'dma': ma[10] == null || ma[50] == null ? null : ma[10]! - ma[50]!,
          'sar': sar,
          'avp': avpVolume == 0 ? null : avpNumerator / avpVolume,
          'ao':
              _average(medianValues, 5) == null ||
                  _average(medianValues, 34) == null
              ? null
              : _average(medianValues, 5)! - _average(medianValues, 34)!,
          'bias': ma[6] == null ? null : (candle.close - ma[6]!) / ma[6]! * 100,
          'br': br,
          'ar': downMoves == 0 ? null : upMoves / downMoves * 100,
          'cci': deviation == null || deviation == 0 || typicalAverage == null
              ? null
              : (typical[i] - typicalAverage) / (0.015 * deviation),
          'cr': cr,
          'dmiPlus': plusDi,
          'dmiMinus': minusDi,
          'adx': plusDi == null || minusDi == null || plusDi + minusDi == 0
              ? null
              : _average(dxValues, 14),
          'emv': _average(emvValues, 14),
          'mtm': i < 10 ? null : candle.close - close[i - 10],
          'obv': obv,
          'pvt': pvt,
          'psy': i < 12
              ? null
              : _sumRange(
                      i,
                      12,
                      (j) => j == 0 || close[j] <= close[j - 1] ? 0 : 1,
                    ) /
                    12 *
                    100,
          'roc': i < 12 || close[i - 12] == 0
              ? null
              : (candle.close - close[i - 12]) / close[i - 12] * 100,
          'trix': trix,
          'trixSignal': signal,
          'vr': vrDown == 0 ? null : vrUp / vrDown * 100,
          'volume': candle.volume,
          'trueRange': trueRange,
          'plusDm': plusDm,
          'minusDm': minusDm,
          'change': changes,
          'previousClose': previousClose,
          'wr': wrHigh == null || wrLow == null || wrHigh == wrLow
              ? null
              : (wrHigh - candle.close) / (wrHigh - wrLow) * -100,
        }),
      );
    }
    return result;
  }

  /// 窗口未满返回 null，例如 MA5 在第 5 根蜡烛才开始有值。
  static double? _average(List<double> values, int n) {
    if (values.length < n) return null;
    final tail = values.skip(values.length - n);
    return tail.reduce((a, b) => a + b) / n;
  }

  static double? _std(List<double> values, int n) {
    final mean = _average(values, n);
    if (mean == null) return null;
    final tail = values.skip(values.length - n);
    return math.sqrt(
      tail.map((value) => math.pow(value - mean, 2)).reduce((a, b) => a + b) /
          n,
    );
  }

  static List<double>? _window(List<double> values, int n) =>
      values.length < n ? null : values.sublist(values.length - n);

  static double? _max(List<double> values, int n) {
    final window = _window(values, n);
    return window?.reduce(math.max).toDouble();
  }

  static double? _min(List<double> values, int n) {
    final window = _window(values, n);
    return window?.reduce(math.min).toDouble();
  }

  static double _sumRange(int index, int n, double Function(int) value) {
    var sum = 0.0;
    final first = index - n + 1 < 0 ? 0 : index - n + 1;
    for (var j = first; j <= index; j++) {
      sum += value(j);
    }
    return sum;
  }

  static double _ema(List<double> values, double value, int n) =>
      values.isEmpty ? value : (2 * value + (n - 1) * values.last) / (n + 1);

  static double? _emaValue(List<double> values, int n) => values.isEmpty
      ? null
      : values.fold<double>(
          values.first,
          (current, next) => (2 * next + (n - 1) * current) / (n + 1),
        );

  /// 当前 RSI 使用最近 n 次涨跌的简单求和口径，学习时应与平滑算法区别核对。
  static double? _rsi(List<double> values, int n) {
    if (values.length <= n) return null;
    var gain = 0.0;
    var loss = 0.0;
    for (var i = values.length - n; i < values.length; i++) {
      final change = values[i] - values[i - 1];
      if (change > 0) gain += change;
      if (change < 0) loss -= change;
    }
    if (loss == 0) return 100;
    return 100 - 100 / (1 + gain / loss);
  }

  static double? _wr(
    List<double> high,
    List<double> low,
    List<double> close,
    int n,
  ) {
    final top = _max(high, n);
    final bottom = _min(low, n);
    if (top == null || bottom == null || top == bottom) return null;
    return (top - close.last) / (top - bottom) * -100;
  }
}

/// 把业务数据映射到 kline_flutter 的开高低收、成交量、时间与指标接口。
class ChartCandleAdapter extends KLineDataAdapter<ChartCandle> {
  const ChartCandleAdapter();

  @override
  double open(ChartCandle item) => item.open;
  @override
  double high(ChartCandle item) => item.high;
  @override
  double low(ChartCandle item) => item.low;
  @override
  double close(ChartCandle item) => item.close;
  @override
  double volume(ChartCandle item) => item.volume;

  @override
  String dateLabel(ChartCandle item) {
    final time = DateTime.fromMillisecondsSinceEpoch(item.time).toLocal();
    return '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  double? indicatorValue(ChartCandle item, String valueId) =>
      item.indicators[valueId];
}

KLineIndicatorSpec<ChartCandle> _spec(
  String id,
  String label,
  List<(String, String)> lines,
) => KLineIndicatorSpec(
  id: id,
  label: label,
  series: [
    for (var i = 0; i < lines.length; i++)
      KLineIndicatorSeries(id: lines[i].$1, label: lines[i].$2, colorIndex: i),
  ],
);

/// 主图指标与价格共用纵轴；名称、序列键和颜色索引在这里绑定。
List<KLineIndicatorSpec<ChartCandle>> get mainChartIndicators => [
  _spec('ma', 'MA', [
    ('ma5', 'MA5'),
    ('ma10', 'MA10'),
    ('ma30', 'MA30'),
    ('ma60', 'MA60'),
  ]),
  KLineDefaultIndicators.ema<ChartCandle>(),
  _spec('sma', 'SMA', [('sma', 'SMA10')]),
  _spec('bbi', 'BBI', [('bbi', 'BBI')]),
  KLineDefaultIndicators.boll<ChartCandle>(),
  _spec('dma', 'DMA', [('dma', 'DMA')]),
  _spec('sar', 'SAR', [('sar', 'SAR')]),
  _spec('avp', 'AVP', [('avp', 'AVP')]),
];

/// 副图指标拥有独立区域，volume 额外绘制成交量柱。
List<KLineIndicatorSpec<ChartCandle>> get secondaryChartIndicators => [
  _spec('ao', 'AO', [('ao', 'AO')]),
  _spec('bias', 'BIAS', [('bias', 'BIAS')]),
  _spec('brar', 'BRAR', [('br', 'BR'), ('ar', 'AR')]),
  _spec('cci', 'CCI', [('cci', 'CCI')]),
  _spec('cr', 'CR', [('cr', 'CR')]),
  _spec('dmi', 'DMI', [
    ('dmiPlus', '+DI'),
    ('dmiMinus', '-DI'),
    ('adx', 'ADX'),
  ]),
  _spec('emv', 'EMV', [('emv', 'EMV')]),
  _spec('mtm', 'MTM', [('mtm', 'MTM')]),
  KLineDefaultIndicators.macd<ChartCandle>(),
  _spec('obv', 'OBV', [('obv', 'OBV')]),
  _spec('pvt', 'PVT', [('pvt', 'PVT')]),
  _spec('psy', 'PSY', [('psy', 'PSY')]),
  _spec('roc', 'ROC', [('roc', 'ROC')]),
  KLineDefaultIndicators.rsi<ChartCandle>(),
  KLineDefaultIndicators.kdj<ChartCandle>(),
  _spec('trix', 'TRIX', [('trix', 'TRIX'), ('trixSignal', 'Signal')]),
  _spec('volume', 'VOL', [
    ('volumeMA5', 'MA5'),
    ('volumeMA10', 'MA10'),
    ('volumeMA20', 'MA20'),
  ]),
  _spec('vr', 'VR', [('vr', 'VR')]),
  KLineDefaultIndicators.wr<ChartCandle>(),
];

List<KLineIndicatorSpec<ChartCandle>> get allChartIndicators => [
  ...mainChartIndicators,
  ...secondaryChartIndicators,
];
