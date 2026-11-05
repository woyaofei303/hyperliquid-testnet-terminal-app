// 四类市场共用的数据模型。coin 用于 API，displayName 用于展示，assetId 用于订单。

enum MarketKind { perpetual, hip3, spot, outcome }

extension MarketKindLabels on MarketKind {
  String get chineseName => switch (this) {
    MarketKind.perpetual => '永续',
    MarketKind.hip3 => 'HIP-3',
    MarketKind.spot => '现货',
    MarketKind.outcome => '预测',
  };

  String get englishName => switch (this) {
    MarketKind.perpetual => 'Perps',
    MarketKind.hip3 => 'HIP-3',
    MarketKind.spot => 'Spot',
    MarketKind.outcome => 'Outcomes',
  };
}

/// 一次行情视图的不可变数据；价格推送通过 withPrice 产生替代对象。
class MarketTicker {
  const MarketTicker({
    required this.coin,
    required this.kind,
    required this.price,
    required this.previousPrice,
    required this.dayVolume,
    required this.sizeDecimals,
    this.assetId,
    this.base,
    this.quote = 'USDC',
    this.label,
    this.dex,
    this.outcomeId,
    this.outcomeSide,
  });

  // 交易所识别名，可能是 BTC、dex:资产名、现货配对名或 #预测编码。
  final String coin;
  final MarketKind kind;
  final double? price;
  final double? previousPrice;
  final double? dayVolume;
  final int sizeDecimals;
  // 签名 action 中的资产编号，由市场元数据确定，缺失时禁止提交。
  final int? assetId;
  final String? base;
  final String quote;
  final String? label;
  final String? dex;
  final int? outcomeId;
  final int? outcomeSide;

  String get displayName => label ?? base ?? coin;

  /// 预测市场使用通用图形；其他市场优先取基础资产名，避免用交易对名称请求图标。
  String? get iconSymbol => kind == MarketKind.outcome ? null : base ?? coin;

  double? get changePercent {
    final current = price;
    final previous = previousPrice;
    if (current == null || previous == null || previous == 0) return null;
    return (current - previous) / previous * 100;
  }

  // 替换价格并保留元数据，因此选择市场时应比较 kind 与 coin，而非对象身份。
  MarketTicker withPrice(double value) => MarketTicker(
    coin: coin,
    kind: kind,
    price: value,
    previousPrice: previousPrice,
    dayVolume: dayVolume,
    sizeDecimals: sizeDecimals,
    assetId: assetId,
    base: base,
    quote: quote,
    label: label,
    dex: dex,
    outcomeId: outcomeId,
    outcomeSide: outcomeSide,
  );
}

double? parseMarketNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
