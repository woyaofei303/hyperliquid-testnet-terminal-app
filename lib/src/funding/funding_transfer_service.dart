// Hyperliquid 内部现货与永续 USDC 划转。重读可用余额后签名，未知回报保留本地记录。

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/diagnostic_http_client.dart';

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';

/// 内部划转核对记录，以账户与 nonce 定位；toPerp 为 true 表示现货转永续。
class PendingFundingTransfer {
  const PendingFundingTransfer({
    required this.address,
    required this.amount,
    required this.toPerp,
    required this.nonce,
    required this.createdAt,
  });

  final String address;
  final String amount;
  final bool toPerp;
  final int nonce;
  final int createdAt;

  factory PendingFundingTransfer.fromJson(Map<String, dynamic> json) =>
      PendingFundingTransfer(
        address: json['address'] as String,
        amount: json['amount'] as String,
        toPerp: json['toPerp'] as bool,
        nonce: json['nonce'] as int,
        createdAt: json['createdAt'] as int,
      );

  Map<String, dynamic> toJson() => {
    'address': address,
    'amount': amount,
    'toPerp': toPerp,
    'nonce': nonce,
    'createdAt': createdAt,
  };
}

/// 处理交易所内部 USDC 划转，查询两侧可用余额并保存未知提交记录。
class FundingTransferService {
  FundingTransferService({
    FlutterSecureStorage? storage,
    InfoClient? info,
    HttpTransport? transport,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _info = info ?? diagnosticInfo(),
       _transport = transport ?? diagnosticTransport();

  static const _storageKey = 'funding.transfers.pending.v1';
  final FlutterSecureStorage _storage;
  final InfoClient _info;
  final HttpTransport _transport;

  void dispose() {
    _info.close();
    _transport.close();
  }

  Future<List<PendingFundingTransfer>> pendingFor(String address) async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return const [];
    final records = (jsonDecode(raw) as List<dynamic>).map(
      (item) => PendingFundingTransfer.fromJson(item as Map<String, dynamic>),
    );
    return records
        .where(
          (record) => record.address.toLowerCase() == address.toLowerCase(),
        )
        .toList();
  }

  /// 重读源账户余额并签名，发送前保存 pending；明确成功或拒绝后移除，网络异常保留。
  Future<void> submit({
    required WalletAdapter wallet,
    required String amount,
    required bool toPerp,
  }) async {
    final normalizedAmount = normalizeTransferAmount(amount);
    final address = await wallet.getAddress();
    if ((await pendingFor(address)).isNotEmpty) {
      throw StateError(
        'Reconcile the previous unconfirmed transfer before submitting another.',
      );
    }

    final states = await Future.wait<Object>([
      _info.clearinghouseState(address),
      _info.spotClearinghouseState(address),
    ]);
    final perp = states[0] as ClearinghouseState;
    final spot = states[1] as SpotClearinghouseState;
    final usdc = spot.balances
        .where((balance) => balance.coin == 'USDC')
        .firstOrNull;
    final spotAvailable = usdc == null
        ? Decimal.zero
        : _nonNegative(Decimal.parse(usdc.total) - Decimal.parse(usdc.hold));
    final perpAvailable = Decimal.parse(perp.withdrawable);
    final available = toPerp ? spotAvailable : perpAvailable;
    if (Decimal.parse(normalizedAmount) > available) {
      throw ArgumentError(
        'Transfer amount is greater than the available source balance.',
      );
    }

    final nonce = DateTime.now().millisecondsSinceEpoch;
    final chain = 'Testnet';
    final action = buildUsdClassTransferAction(
      amount: normalizedAmount,
      toPerp: toPerp,
      nonce: nonce,
    );
    final signature = await signUserSignedAction(
      wallet: wallet,
      hyperliquidChain: chain,
      primaryType: 'HyperliquidTransaction:UsdClassTransfer',
      message: {
        'hyperliquidChain': chain,
        'amount': normalizedAmount,
        'toPerp': toPerp,
        'nonce': nonce,
      },
    );
    final pending = PendingFundingTransfer(
      address: address,
      amount: normalizedAmount,
      toPerp: toPerp,
      nonce: nonce,
      createdAt: nonce,
    );
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
        await _remove(pending);
        throw FundingTransferRejected(
          response.errorMessage ?? 'The exchange rejected the transfer.',
        );
      }
      await _remove(pending);
    } on FundingTransferRejected {
      rethrow;
    } catch (error, stack) {
      AppDiagnostics.instance.error(
        'funding.transfer',
        error,
        stack,
        remote: false,
      );
      throw FundingTransferOutcomeUnknown(pending, error);
    }
  }

  /// 用户核对两侧余额之后解除本地记录，此方法不发送任何新划转。
  Future<void> resolveAfterManualCheck(PendingFundingTransfer pending) async {
    await _remove(pending);
  }

  /// 签名域 chainId 来自协议规范，hyperliquidChain 与测试网 transport 共同指定环境。
  static Map<String, dynamic> buildUsdClassTransferAction({
    required String amount,
    required bool toPerp,
    required int nonce,
  }) => {
    'type': 'usdClassTransfer',
    'hyperliquidChain': 'Testnet',
    'signatureChainId': '0xa4b1',
    'amount': amount,
    'toPerp': toPerp,
    'nonce': nonce,
  };

  /// USDC 最多六位小数，保持字符串精度并去掉无意义尾零。
  static String normalizeTransferAmount(String input) {
    final value = input.trim();
    if (value.length > 40 ||
        !RegExp(r'^(0|[1-9]\d*)(\.\d+)?$').hasMatch(value)) {
      throw ArgumentError('Amount must be a plain decimal number.');
    }
    final amount = Decimal.parse(value);
    if (amount <= Decimal.zero || amount.scale > 6) {
      throw ArgumentError(
        'Amount must be positive and use at most 6 decimal places.',
      );
    }
    return amount.toString();
  }

  Decimal _nonNegative(Decimal amount) =>
      amount < Decimal.zero ? Decimal.zero : amount;

  Future<List<PendingFundingTransfer>> _allPending() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List<dynamic>)
        .map(
          (item) =>
              PendingFundingTransfer.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> _remove(PendingFundingTransfer transfer) async => _savePending(
    (await _allPending())
        .where(
          (item) =>
              item.address.toLowerCase() != transfer.address.toLowerCase() ||
              item.nonce != transfer.nonce,
        )
        .toList(),
  );

  Future<void> _savePending(List<PendingFundingTransfer> records) =>
      _storage.write(
        key: _storageKey,
        value: jsonEncode(records.map((record) => record.toJson()).toList()),
      );
}

class FundingTransferRejected implements Exception {
  const FundingTransferRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

class FundingTransferOutcomeUnknown implements Exception {
  const FundingTransferOutcomeUnknown(this.pending, this.cause);
  final PendingFundingTransfer pending;
  final Object cause;
  @override
  String toString() =>
      'Transfer result is unknown. Check both balances before clearing this record: $cause';
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
