// 订单 action 构造、签名提交和未知回报核对。发送前保存 cloid，避免超时后盲目重发。

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/diagnostic_http_client.dart';

import 'dart:convert';
import 'dart:math';

import 'package:decimal/decimal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';

import '../market/market.dart';
import 'order_safety.dart';

/// 发送前保留的核对凭据，cloid 是 App 随机生成的 128 位客户端订单号。
class PendingOrder {
  const PendingOrder({
    required this.address,
    required this.coin,
    required this.cloid,
    required this.price,
    required this.size,
    required this.createdAt,
  });

  final String address;
  final String coin;
  final String cloid;
  final String price;
  final String size;
  final int createdAt;

  factory PendingOrder.fromJson(Map<String, dynamic> json) => PendingOrder(
    address: json['address'] as String,
    coin: json['coin'] as String,
    cloid: json['cloid'] as String,
    price: json['price'] as String,
    size: json['size'] as String,
    createdAt: json['createdAt'] as int,
  );

  Map<String, dynamic> toJson() => {
    'address': address,
    'coin': coin,
    'cloid': cloid,
    'price': price,
    'size': size,
    'createdAt': createdAt,
  };
}

/// 区分已挂单、成交、部分成交和无法辨认的回报，unknown 需要后续核对。
enum SubmissionState { resting, filled, partial, unknown }

class OrderSubmission {
  const OrderSubmission({
    required this.cloid,
    required this.state,
    this.message,
  });

  final String cloid;
  final SubmissionState state;
  final String? message;
}

/// 表示无法确定交易所是否接受请求，调用方应保留 cloid 并阻止盲目重发。
class OrderOutcomeUnknown implements Exception {
  const OrderOutcomeUnknown(this.cloid, this.cause);

  final String cloid;
  final Object cause;

  @override
  String toString() => 'Order outcome is unknown for $cloid: $cause';
}

class OrderRejected implements Exception {
  const OrderRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 校验和构造 action 后调用 SDK 签名，通过测试网 exchange 接口提交。
class OrderSubmissionService {
  OrderSubmissionService({
    FlutterSecureStorage? storage,
    HttpTransport? transport,
    Random? random,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _transport = transport ?? diagnosticTransport(),
       _random = random ?? Random.secure();

  static const _pendingKey = 'orders.pending.v1';
  final FlutterSecureStorage _storage;
  final HttpTransport _transport;
  final Random _random;

  Future<List<PendingOrder>> pendingFor(String address) async {
    final raw = await _storage.read(key: _pendingKey);
    if (raw == null) return const [];
    final orders = (jsonDecode(raw) as List<dynamic>).map(
      (item) => PendingOrder.fromJson(item as Map<String, dynamic>),
    );
    return orders
        .where((order) => order.address.toLowerCase() == address.toLowerCase())
        .toList();
  }

  /// 签名失败发生在保存 pending 之前；一旦准备发送，先持久化，再发 HTTP 请求。
  Future<OrderSubmission> submit({
    required WalletAdapter wallet,
    required MarketTicker market,
    required bool isBuy,
    required String price,
    required String size,
    required TimeInForce tif,
    bool reduceOnly = false,
    String? triggerPx,
    TpslType? triggerKind,
    bool triggerIsMarket = true,
  }) async {
    final validated = validateOrderDraft(
      market: market,
      price: price,
      size: size,
      reduceOnly: reduceOnly,
    );
    final address = await wallet.getAddress();
    if ((await pendingFor(address)).isNotEmpty) {
      throw StateError(
        'Reconcile the previous unconfirmed request before submitting another order.',
      );
    }
    final cloid = _newCloid();
    final action = buildOrderAction(
      market: market,
      isBuy: isBuy,
      price: validated.price,
      size: validated.size,
      cloid: cloid,
      tif: tif,
      reduceOnly: reduceOnly,
      triggerPx: triggerPx,
      triggerKind: triggerKind,
      triggerIsMarket: triggerIsMarket,
    );
    final nonce = DateTime.now().millisecondsSinceEpoch;
    // 这里使用 Hyperliquid L1 action 签名规范，资金划转使用另一种 user-signed 规范。
    final signature = await signL1Action(
      wallet: wallet,
      action: action,
      nonce: nonce,
      isTestnet: true,
    );
    final pending = PendingOrder(
      address: address,
      coin: market.coin,
      cloid: cloid,
      price: validated.price,
      size: validated.size,
      createdAt: nonce,
    );
    // 发送可能已经被服务端接受，即使本地超时也必须留下可核对记录。
    await _savePending([...await _allPending(), pending]);

    try {
      final response = ExchangeResponse.fromJson(
        await _transport.postExchange({
          'action': action,
          'nonce': nonce,
          'signature': signature.toJson(),
        }) as Map<String, dynamic>,
      );
      if (response.isError) {
        await _removePending(cloid);
        throw OrderRejected(
          response.errorMessage ?? 'The exchange rejected the order.',
        );
      }
      final status = _firstStatus(response.response);
      if (status is Map<String, dynamic> && status.containsKey('error')) {
        await _removePending(cloid);
        throw OrderRejected(
          status['error'] as String? ?? 'The exchange rejected the order.',
        );
      }
      if (status is Map<String, dynamic> && status.containsKey('resting')) {
        await _removePending(cloid);
        return OrderSubmission(cloid: cloid, state: SubmissionState.resting);
      }
      if (status is Map<String, dynamic> && status.containsKey('filled')) {
        await _removePending(cloid);
        final filled = status['filled'];
        final filledSize = filled is Map
            ? Decimal.tryParse('${filled['totalSz']}') ?? Decimal.zero
            : Decimal.zero;
        return OrderSubmission(
          cloid: cloid,
          state:
              filledSize > Decimal.zero &&
                  filledSize < Decimal.parse(validated.size)
              ? SubmissionState.partial
              : SubmissionState.filled,
        );
      }
      return OrderSubmission(cloid: cloid, state: SubmissionState.unknown);
    } on OrderRejected {
      rethrow;
    } catch (error, stack) {
      AppDiagnostics.instance.error(
        'order.submit',
        error,
        stack,
        remote: false,
      );
      throw OrderOutcomeUnknown(cloid, error);
    }
  }

  /// 使用 cloid 查询订单状态；确认已找到或超过 30 秒仍 unknownOid 时才解除本地记录。
  Future<String> reconcile(PendingOrder pending) async {
    final response = await _transport.postInfo({
      'type': 'orderStatus',
      'user': pending.address,
      'oid': pending.cloid,
    });
    final status = response is Map<String, dynamic> ? response['status'] : null;
    if (status == 'order') {
      await _removePending(pending.cloid);
      return 'found';
    }
    if (status == 'unknownOid' &&
        DateTime.now().millisecondsSinceEpoch - pending.createdAt >= 30000) {
      await _removePending(pending.cloid);
      return 'expired';
    }
    return 'pending';
  }

  /// 只构造协议对象，便于离线检查字段。c 是 cloid，grouping 为独立订单。
  static Map<String, dynamic> buildOrderAction({
    required MarketTicker market,
    required bool isBuy,
    required String price,
    required String size,
    required String cloid,
    required TimeInForce tif,
    required bool reduceOnly,
    String? triggerPx,
    TpslType? triggerKind,
    bool triggerIsMarket = true,
  }) {
    final asset = market.assetId;
    if (asset == null) throw ArgumentError('Market asset id is missing.');
    final wire = triggerPx == null
        ? OrderWire.limit(
            asset: asset,
            isBuy: isBuy,
            limitPx: price,
            sz: size,
            tif: tif,
            reduceOnly: reduceOnly,
          ).toWire()
        : OrderWire.trigger(
            asset: asset,
            isBuy: isBuy,
            limitPx: price,
            sz: size,
            triggerPx: triggerPx,
            tpsl: triggerKind ?? TpslType.sl,
            isMarket: triggerIsMarket,
            reduceOnly: reduceOnly,
          ).toWire();
    wire['c'] = cloid;
    return {
      'type': 'order',
      'orders': [wire],
      'grouping': OrderGrouping.na.value,
    };
  }

  Object? _firstStatus(Object? response) {
    if (response is! Map) return null;
    final data = response['data'];
    if (data is! Map || data['statuses'] is! List) return null;
    final statuses = data['statuses'] as List;
    return statuses.isEmpty ? null : statuses.first;
  }

  String _newCloid() =>
      '0x${List<int>.generate(16, (_) => _random.nextInt(256)).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';

  Future<List<PendingOrder>> _allPending() async {
    final raw = await _storage.read(key: _pendingKey);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List<dynamic>)
        .map((item) => PendingOrder.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> _removePending(String cloid) async {
    await _savePending(
      (await _allPending()).where((order) => order.cloid != cloid).toList(),
    );
  }

  Future<void> _savePending(List<PendingOrder> orders) => _storage.write(
    key: _pendingKey,
    value: jsonEncode(orders.map((order) => order.toJson()).toList()),
  );
}
