// 使用固定市场元数据验证精度、最小名义金额和订单 wire 字段；不发送订单，也不证明真实签名已被交易所接受。

import 'package:flutter_test/flutter_test.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:hyperliquid_testnet_terminal/src/market/market.dart';
import 'package:hyperliquid_testnet_terminal/src/trading/order_safety.dart';
import 'package:hyperliquid_testnet_terminal/src/trading/order_submission_service.dart';

const btc = MarketTicker(
  coin: 'BTC',
  kind: MarketKind.perpetual,
  price: 60000,
  previousPrice: 59000,
  dayVolume: 10,
  sizeDecimals: 5,
  assetId: 0,
);

void main() {
  test('valid order preserves user size and computes exact notional', () {
    final order = validateOrderDraft(
      market: btc,
      price: '60000',
      size: '0.001',
    );

    expect(order.price, '60000');
    expect(order.size, '0.001');
    expect(order.notional.toString(), '60');
  });

  test('rejects amount precision beyond the exchange market metadata', () {
    expect(
      () => validateOrderDraft(market: btc, price: '60000', size: '0.000001'),
      throwsArgumentError,
    );
  });

  test('rejects prices that exceed five significant figures', () {
    expect(
      () => validateOrderDraft(market: btc, price: '60000.5', size: '0.001'),
      throwsArgumentError,
    );
  });

  test('enforces the testnet market minimum order value', () {
    expect(
      () => validateOrderDraft(market: btc, price: '60000', size: '0.0001'),
      throwsArgumentError,
    );
  });

  test('builds the same limit wire fields and grouping as the web request', () {
    final action = OrderSubmissionService.buildOrderAction(
      market: btc,
      isBuy: true,
      price: '60000',
      size: '0.001',
      cloid: '0x${List.filled(16, '11').join()}',
      tif: TimeInForce.gtc,
      reduceOnly: false,
    );

    expect(action, {
      'type': 'order',
      'orders': [
        {
          'a': 0,
          'b': true,
          'p': '60000',
          's': '0.001',
          'r': false,
          't': {
            'limit': {'tif': 'Gtc'},
          },
          'c': '0x${List.filled(16, '11').join()}',
        },
      ],
      'grouping': 'na',
    });
  });

  test('builds an exchange trigger order with TP or SL classification', () {
    final action = OrderSubmissionService.buildOrderAction(
      market: btc,
      isBuy: false,
      price: '61000',
      size: '0.001',
      cloid: '0x${List.filled(16, '22').join()}',
      tif: TimeInForce.gtc,
      reduceOnly: true,
      triggerPx: '61000',
      triggerKind: TpslType.sl,
    );

    expect(action['orders'], [
      {
        'a': 0,
        'b': false,
        'p': '61000',
        's': '0.001',
        'r': true,
        't': {
          'trigger': {'isMarket': true, 'triggerPx': '61000', 'tpsl': 'sl'},
        },
        'c': '0x${List.filled(16, '22').join()}',
      },
    ]);
  });

  test('builds a trigger limit order with the exchange limit trigger flag', () {
    final action = OrderSubmissionService.buildOrderAction(
      market: btc,
      isBuy: true,
      price: '60000',
      size: '0.001',
      cloid: '0x${List.filled(16, '33').join()}',
      tif: TimeInForce.gtc,
      reduceOnly: false,
      triggerPx: '61000',
      triggerKind: TpslType.sl,
      triggerIsMarket: false,
    );

    expect((action['orders'] as List).single['t'], {
      'trigger': {'isMarket': false, 'triggerPx': '61000', 'tpsl': 'sl'},
    });
  });
}
