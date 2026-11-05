// 订单输入校验和滑点限价计算。金额使用 Decimal，输出保留十进制字符串供签名使用。

import 'dart:math' as math;

import 'package:decimal/decimal.dart';

import '../market/market.dart';

/// 通过校验的字符串价格、数量和精确名义金额，可直接用于订单 wire。
class ValidatedOrder {
  const ValidatedOrder({
    required this.price,
    required this.size,
    required this.notional,
  });

  final String price;
  final String size;
  final Decimal notional;
}

/// 同时校验元数据、数量和价格精度、预测价格范围及最低名义金额，失败抛出 ArgumentError。
ValidatedOrder validateOrderDraft({
  required MarketTicker market,
  required String price,
  required String size,
  bool reduceOnly = false,
}) {
  if (market.assetId == null ||
      market.sizeDecimals < 0 ||
      market.sizeDecimals > (market.kind == MarketKind.spot ? 8 : 6)) {
    throw ArgumentError('Market precision metadata is invalid.');
  }
  if (market.kind == MarketKind.outcome && market.sizeDecimals != 0) {
    throw ArgumentError('Outcome market size must be an integer.');
  }
  if (reduceOnly &&
      market.kind != MarketKind.perpetual &&
      market.kind != MarketKind.hip3) {
    throw ArgumentError('Reduce-only is available only for perpetual markets.');
  }

  final parsedPrice = _positiveDecimal(price, 'Price');
  final parsedSize = _positiveDecimal(size, 'Size');
  if (parsedSize.scale > market.sizeDecimals) {
    throw ArgumentError('Size exceeds this market’s decimal precision.');
  }

  final allowedPriceDecimals = _priceDecimals(market, parsedPrice);
  if (parsedPrice.scale > allowedPriceDecimals) {
    throw ArgumentError('Price exceeds this market’s decimal precision.');
  }
  if (market.kind == MarketKind.outcome &&
      (parsedPrice < Decimal.parse('0.00001') ||
          parsedPrice > Decimal.parse('0.99999'))) {
    throw ArgumentError('Outcome price must be between 0.00001 and 0.99999.');
  }

  final notional = parsedPrice * parsedSize;
  final minimum = Decimal.fromInt(market.kind == MarketKind.outcome ? 1 : 10);
  if (!reduceOnly && notional < minimum) {
    throw ArgumentError(
      'Order value must be at least $minimum ${market.quote}.',
    );
  }
  return ValidatedOrder(
    price: parsedPrice.toString(),
    size: parsedSize.toString(),
    notional: notional,
  );
}

/// 只接受普通十进制正数，拒绝科学计数法、符号和过长输入。
Decimal _positiveDecimal(String input, String label) {
  final value = input.trim();
  if (value.length > 40 || !RegExp(r'^(0|[1-9]\d*)(\.\d+)?$').hasMatch(value)) {
    throw ArgumentError('$label must be a plain decimal number.');
  }
  final parsed = Decimal.parse(value);
  if (parsed <= Decimal.zero) {
    throw ArgumentError('$label must be greater than zero.');
  }
  return parsed;
}

/// 结合五位有效数字与市场小数上限计算允许位数，整数价允许零位小数。
int _priceDecimals(MarketTicker market, Decimal price) {
  if (market.kind == MarketKind.outcome) return 5;
  var exponent = 0;
  var scaled = price;
  while (scaled >= Decimal.fromInt(10)) {
    scaled = (scaled / Decimal.fromInt(10)).toDecimal();
    exponent++;
  }
  while (scaled < Decimal.one) {
    scaled *= Decimal.fromInt(10);
    exponent--;
  }
  final decimalCap =
      (market.kind == MarketKind.spot ? 8 : 6) - market.sizeDecimals;
  return math.max(0, math.min(decimalCap, 4 - exponent));
}

/// 市价单实际使用 IOC 限价保护。1 bps = 0.01%，买单向下、卖单向上舍入以收紧保护价。
String marketSlippagePrice({
  required MarketTicker market,
  required bool isBuy,
  required int slippageBps,
}) {
  final current = market.price;
  if (current == null || !current.isFinite || current <= 0) {
    throw ArgumentError('A fresh market price is required.');
  }
  if (slippageBps < 1 || slippageBps > 1000) {
    throw ArgumentError('Slippage must be between 1 and 1000 basis points.');
  }
  final midpoint = Decimal.parse(current.toString());
  final change = Decimal.fromInt(
    isBuy ? 10000 + slippageBps : 10000 - slippageBps,
  );
  final adjusted = (midpoint * change / Decimal.fromInt(10000)).toDecimal();
  final withSignificantDigits = _roundSignificant(adjusted, 5, isBuy);
  final decimals = _priceDecimals(market, withSignificantDigits);
  final rounded = isBuy
      ? withSignificantDigits.floor(scale: decimals)
      : withSignificantDigits.ceil(scale: decimals);
  if (market.kind == MarketKind.outcome) {
    return rounded
        .clamp(Decimal.parse('0.00001'), Decimal.parse('0.99999'))
        .toString();
  }
  if (rounded <= Decimal.zero) {
    throw ArgumentError('Slippage price is below market precision.');
  }
  return rounded.toString();
}

Decimal _roundSignificant(Decimal value, int digits, bool floor) {
  var exponent = 0;
  var scaled = value;
  while (scaled >= Decimal.fromInt(10)) {
    scaled = (scaled / Decimal.fromInt(10)).toDecimal();
    exponent++;
  }
  while (scaled < Decimal.one) {
    scaled *= Decimal.fromInt(10);
    exponent--;
  }
  final places = math.max(0, digits - exponent - 1);
  return floor ? value.floor(scale: places) : value.ceil(scale: places);
}
