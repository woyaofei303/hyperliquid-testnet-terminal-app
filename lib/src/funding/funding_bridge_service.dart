// Arbitrum Sepolia 与 Hyperliquid 测试网之间的 CCTP 资金流程。
// 分开记录已提交、链上确认与到账核验，避免把交易哈希当作到账证明。

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/diagnostic_http_client.dart';

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:http/http.dart' as http;

import '../wallet/evm_transaction_wallet.dart';

// 本实现的资金源链配置；CCTP domain 与 EVM chainId 属于不同编号体系。
const depositChainId = 421614;
const depositRpc = 'https://sepolia-rollup.arbitrum.io/rpc';
const hyperEvmRpc = 'https://rpc.hyperliquid-testnet.xyz/evm';
const depositUsdc = '0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d';
const tokenMessenger = '0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA';
const cctpForwarder = '0x02e39ECb8368b41bF68FF99ff351aC9864e5E2a2';
const withdrawalFee = '0.2';

enum FundingActionKind { approve, deposit, withdraw }

/// unknown 待核对，submitted 已提交，credited 已核验到账，reverted 明确失败。
/// confirmed 是中间证据状态；提款在索引找到哈希时进入，随后还需检查目标链回执。
enum FundingActionStatus { unknown, submitted, confirmed, credited, reverted }

/// 跨链状态记录，支持进程重启后继续核验；时间为毫秒，amount 为 USDC 十进制字符串。
class PendingFundingAction {
  const PendingFundingAction({
    required this.account,
    required this.amount,
    required this.kind,
    required this.createdAt,
    required this.status,
    this.nonce,
    this.sourceDex,
    this.hash,
  });

  final String account;
  final String amount;
  final FundingActionKind kind;
  final int createdAt;
  final FundingActionStatus status;
  final int? nonce;
  final String? sourceDex;
  final String? hash;

  PendingFundingAction copyWith({FundingActionStatus? status, String? hash}) =>
      PendingFundingAction(
        account: account,
        amount: amount,
        kind: kind,
        createdAt: createdAt,
        status: status ?? this.status,
        nonce: nonce,
        sourceDex: sourceDex,
        hash: hash == null ? this.hash : _validateFundingHash(hash),
      );

  /// 历史本地数据也必须校验账户、哈希和金额，再用于链上核验。
  factory PendingFundingAction.fromJson(Map<String, dynamic> json) {
    final record = PendingFundingAction(
      account: json['account'] as String,
      amount: json['amount'] as String,
      kind: FundingActionKind.values.byName(json['kind'] as String),
      createdAt: json['createdAt'] as int,
      status: FundingActionStatus.values.byName(json['status'] as String),
      nonce: json['nonce'] as int?,
      sourceDex: json['sourceDex'] as String?,
      hash: json['hash'] as String?,
    );
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(record.account) ||
        (record.kind == FundingActionKind.withdraw &&
            (record.nonce == null ||
                !['', 'spot'].contains(record.sourceDex)))) {
      throw const FormatException('Saved funding record is invalid.');
    }
    if (record.hash != null) _validateFundingHash(record.hash!);
    fundingAmountUnits(
      record.amount,
      withdrawal: record.kind == FundingActionKind.withdraw,
    );
    return record;
  }

  Map<String, dynamic> toJson() => {
    'account': account,
    'amount': amount,
    'kind': kind.name,
    'createdAt': createdAt,
    'status': status.name,
    if (nonce != null) 'nonce': nonce,
    if (sourceDex != null) 'sourceDex': sourceDex,
    if (hash != null) 'hash': hash,
  };
}

/// USDC 与 allowance 使用六位小数的最小单位，gasWei 使用 ETH 的 wei 单位。
class DepositBalances {
  const DepositBalances({
    required this.usdc,
    required this.allowance,
    required this.gasWei,
  });

  final BigInt usdc;
  final BigInt allowance;
  final BigInt gasWei;
}

/// 确认页的提款快照，包含来源账户、可提金额和网络费；提交时重新读取并比较。
class WithdrawalQuote {
  const WithdrawalQuote({
    required this.account,
    required this.sourceDex,
    required this.gasHype,
    required this.gasUsdc,
    required this.gasInHype,
    required this.activationFee,
    required this.available,
    required this.at,
  });

  final String account;
  final String sourceDex;
  final String gasHype;
  final String gasUsdc;
  final bool gasInHype;
  final String activationFee;
  final String available;
  final int at;
}

/// 把 USDC 转成整数最小单位，例如 12.34 变为 12340000，避免浮点舍入。
BigInt fundingAmountUnits(String input, {bool withdrawal = false}) {
  final value = input.trim();
  final match = RegExp(r'^(0|[1-9]\d*)(?:\.(\d+))?$').firstMatch(value);
  if (match == null || (match[2]?.length ?? 0) > 6) {
    throw ArgumentError(
      'USDC amount must be a plain number with at most 6 decimals.',
    );
  }
  final whole = BigInt.parse(match[1]!);
  final fraction = BigInt.parse((match[2] ?? '').padRight(6, '0').ifEmpty('0'));
  final amount = whole * BigInt.from(1000000) + fraction;
  final minimum = withdrawal ? BigInt.from(400000) : BigInt.from(5000000);
  final maximum = BigInt.from(10000000000000);
  if (amount < minimum || (withdrawal ? amount > maximum : amount >= maximum)) {
    throw ArgumentError(
      withdrawal
          ? 'Withdrawal must be from 0.4 to 10,000,000 USDC.'
          : 'Deposit must be at least 5 and less than 10,000,000 USDC.',
    );
  }
  return amount;
}

String normalizeFundingAmount(String input, {bool withdrawal = false}) {
  fundingAmountUnits(input, withdrawal: withdrawal);
  return Decimal.parse(input.trim()).toString();
}

bool sameFundingWallet(String expected, String connected) =>
    expected.toLowerCase() == connected.toLowerCase();

/// 编码 USDC approve，授权额度按本次金额设置给固定的 TokenMessenger。
String approveUsdcCalldata(String amount) =>
    '0x095ea7b3${_addressWord(tokenMessenger)}${_word(fundingAmountUnits(amount))}';

/// 编码带 Hook 的 CCTP 存款调用，末尾动态 bytes 按 ABI 长度与 32 字节对齐补位。
String depositForBurnCalldata(String amount, String receiver) {
  _validateAddress(receiver);
  final hook = _hookData(receiver);
  return '0x779b432d'
      '${_word(fundingAmountUnits(amount))}'
      '${_word(BigInt.from(19))}'
      '${_addressBytes32(cctpForwarder)}'
      '${_addressWord(depositUsdc)}'
      '${_addressBytes32(cctpForwarder)}'
      '${_word(BigInt.from(200000))}'
      '${_word(BigInt.from(1000))}'
      '${_word(BigInt.from(256))}'
      '${_word(BigInt.from(hook.length ~/ 2))}'
      '${hook.padRight(((hook.length + 63) ~/ 64) * 64, '0')}';
}

/// 提款是发给 Hyperliquid 的 action，nonce 随后用于匹配跨链索引记录。
Map<String, dynamic> buildSendToEvmWithDataAction({
  required String address,
  required String amount,
  required int nonce,
  String sourceDex = '',
}) => {
  'type': 'sendToEvmWithData',
  'signatureChainId': '0xa4b1',
  'hyperliquidChain': 'Testnet',
  'token': 'USDC',
  'amount': normalizeFundingAmount(amount, withdrawal: true),
  'sourceDex': sourceDex,
  'destinationRecipient': _validateAddress(address).toLowerCase(),
  'addressEncoding': 'hex',
  'destinationChainId': 3,
  'gasLimit': 200000,
  'data': '0x',
  'nonce': nonce,
};

/// EIP-712 的类型、字段顺序和签名域属于协议内容，修改时须同步对照测试。
Map<String, dynamic> buildSendToEvmWithDataTypedData(
  Map<String, dynamic> action,
) => {
  'domain': {
    'name': 'HyperliquidSignTransaction',
    'version': '1',
    'chainId': 42161,
    'verifyingContract': '0x0000000000000000000000000000000000000000',
  },
  'types': {
    'EIP712Domain': [
      {'name': 'name', 'type': 'string'},
      {'name': 'version', 'type': 'string'},
      {'name': 'chainId', 'type': 'uint256'},
      {'name': 'verifyingContract', 'type': 'address'},
    ],
    'HyperliquidTransaction:SendToEvmWithData': [
      {'name': 'hyperliquidChain', 'type': 'string'},
      {'name': 'token', 'type': 'string'},
      {'name': 'amount', 'type': 'string'},
      {'name': 'sourceDex', 'type': 'string'},
      {'name': 'destinationRecipient', 'type': 'string'},
      {'name': 'addressEncoding', 'type': 'string'},
      {'name': 'destinationChainId', 'type': 'uint32'},
      {'name': 'gasLimit', 'type': 'uint64'},
      {'name': 'data', 'type': 'bytes'},
      {'name': 'nonce', 'type': 'uint64'},
    ],
  },
  'primaryType': 'HyperliquidTransaction:SendToEvmWithData',
  'message': {
    for (final field in const [
      'hyperliquidChain',
      'token',
      'amount',
      'sourceDex',
      'destinationRecipient',
      'addressEncoding',
      'destinationChainId',
      'gasLimit',
      'data',
      'nonce',
    ])
      field: action[field],
  },
};

/// 提交前用重新读取的可提余额校验用户金额，返回精确十进制表示。
String withdrawalAmount(String input, String available) {
  fundingAmountUnits(input, withdrawal: true);
  final maximum = Decimal.parse(available);
  if (maximum < Decimal.zero || Decimal.parse(input) > maximum) {
    throw ArgumentError(
      'Withdrawal amount exceeds the refreshed available balance.',
    );
  }
  return Decimal.parse(input.trim()).toString();
}

/// 跨链交易 confirmed 后仍等待 credited，因此继续阻止同账户重复资金操作。
bool isFundingActionPending(PendingFundingAction record) =>
    record.status == FundingActionStatus.unknown ||
    record.status == FundingActionStatus.submitted ||
    ((record.kind == FundingActionKind.deposit ||
            record.kind == FundingActionKind.withdraw) &&
        record.status == FundingActionStatus.confirmed);

/// 源交易哈希先匹配跨链 nonce，再匹配目标账户账本中的接收地址和 USDC 记录。
bool creditedDeposit(
  List<dynamic> transfers,
  List<dynamic> ledger,
  PendingFundingAction record,
) {
  final hash = record.hash?.toLowerCase();
  if (hash == null || record.kind != FundingActionKind.deposit) return false;
  final matchingTransfer = transfers.whereType<Map>().where(
    (transfer) =>
        '${transfer['depositTxnRef']}'.toLowerCase() == hash &&
        '${transfer['originChainId']}' == '$depositChainId',
  );
  if (matchingTransfer.isEmpty) return false;
  final nonce = '${matchingTransfer.first['nonce']}';
  return ledger.any((entry) {
    final delta = entry is Map ? entry['delta'] : null;
    return delta is Map &&
        delta['type'] == 'send' &&
        '${delta['destination']}'.toLowerCase() ==
            record.account.toLowerCase() &&
        '${delta['nonce']}' == nonce &&
        '${delta['token']}'.startsWith('USDC:');
  });
}

/// 按本次提款 nonce 与目标链筛选回填交易哈希，避免捡到其他资金操作。
String? withdrawalTransaction(
  List<dynamic> transfers,
  PendingFundingAction record,
) {
  if (record.kind != FundingActionKind.withdraw || record.nonce == null) {
    return null;
  }
  for (final item in transfers.whereType<Map>()) {
    if ('${item['nonce']}' == '${record.nonce}' &&
        '${item['destinationChainId']}' == '$depositChainId' &&
        item['fillTxnRef'] is String &&
        RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(item['fillTxnRef'] as String)) {
      return item['fillTxnRef'] as String;
    }
  }
  return null;
}

/// 检查目标链 USDC Transfer 日志的接收者和净金额，净金额扣除本实现固定的 0.2 USDC 费用。
bool receivedWithdrawal(List<dynamic> logs, PendingFundingAction record) {
  final expected =
      fundingAmountUnits(record.amount, withdrawal: true) - BigInt.from(200000);
  const topic =
      '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
  for (final log in logs.whereType<Map>()) {
    final topics = log['topics'];
    if ('${log['address']}'.toLowerCase() != depositUsdc.toLowerCase() ||
        topics is! List ||
        topics.length < 3 ||
        '${topics[0]}'.toLowerCase() != topic ||
        '${topics[2]}'.toLowerCase() != _addressTopic(record.account) ||
        log['data'] is! String) {
      continue;
    }
    final data = (log['data'] as String).replaceFirst('0x', '');
    final value = BigInt.tryParse(data, radix: 16);
    if (value != null && value >= expected) return true;
  }
  return false;
}

/// 协调余额查询、授权、提交和跨链核验，transport 与 RPC 客户端可注入替身。
class FundingBridgeService {
  FundingBridgeService({
    FlutterSecureStorage? storage,
    HttpTransport? transport,
    http.Client? rpcClient,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _transport = transport ?? diagnosticTransport(),
       _rpcClient = rpcClient ?? DiagnosticHttpClient();

  static const _storageKey = 'funding.bridge.pending.v1';
  final FlutterSecureStorage _storage;
  final HttpTransport _transport;
  final http.Client _rpcClient;
  int _rpcId = 0;

  void dispose() {
    _transport.close();
    _rpcClient.close();
  }

  Future<List<PendingFundingAction>> pendingFor(String address) async =>
      (await _all())
          .where(
            (record) =>
                record.account.toLowerCase() == address.toLowerCase() &&
                isFundingActionPending(record),
          )
          .toList();

  /// 并发只读查询 USDC 余额、TokenMessenger 授权量和源链 ETH 余额。
  Future<DepositBalances> depositBalances(String address) async {
    final result = await Future.wait([
      _rpc(depositRpc, 'eth_call', [
        {'to': depositUsdc, 'data': '0x70a08231${_addressWord(address)}'},
        'latest',
      ]),
      _rpc(depositRpc, 'eth_call', [
        {
          'to': depositUsdc,
          'data':
              '0xdd62ed3e${_addressWord(address)}${_addressWord(tokenMessenger)}',
        },
        'latest',
      ]),
      _rpc(depositRpc, 'eth_getBalance', [address, 'latest']),
    ]);
    return DepositBalances(
      usdc: _quantity(result[0]),
      allowance: _quantity(result[1]),
      gasWei: _quantity(result[2]),
    );
  }

  Future<void> switchDepositChain(EvmTransactionWallet wallet) =>
      wallet.switchToChain(depositChainId);

  /// 授权不足时先等待授权回执，再检查账户和授权量，最后模拟并提交存款交易。
  Future<PendingFundingAction> submitDeposit({
    required WalletAdapter wallet,
    required String expectedAddress,
    required String amount,
    required Future<void> Function() ensureActiveWallet,
  }) async {
    if (wallet is! EvmTransactionWallet) {
      throw StateError('This wallet cannot send Arbitrum transactions.');
    }
    final evmWallet = wallet as EvmTransactionWallet;
    final address = await wallet.getAddress();
    if (!sameFundingWallet(expectedAddress, address)) {
      throw StateError(
        'The connected wallet changed. Reopen the funding form.',
      );
    }
    await _assertNoPending(address);
    final units = fundingAmountUnits(amount);
    await evmWallet.switchToChain(depositChainId);
    await ensureActiveWallet();
    var balances = await depositBalances(address);
    if (balances.usdc < units) {
      throw StateError('Arbitrum Sepolia USDC balance is too low.');
    }
    if (balances.gasWei == BigInt.zero) {
      throw StateError('Arbitrum Sepolia ETH is required for gas.');
    }

    if (balances.allowance < units) {
      final approval = await _sendSourceTransaction(
        wallet: evmWallet,
        address: address,
        amount: amount,
        kind: FundingActionKind.approve,
        data: approveUsdcCalldata(amount),
        ensureActiveWallet: ensureActiveWallet,
      );
      final receipt = await _waitForReceipt(approval.hash!);
      if (receipt == null) {
        throw FundingBridgeOutcomeUnknown(
          approval,
          'Approval was submitted, but its receipt is not confirmed yet.',
        );
      }
      if (!_receiptSucceeded(receipt)) {
        await _save(approval.copyWith(status: FundingActionStatus.reverted));
        throw StateError('USDC approval reverted. The deposit was not sent.');
      }
      await _remove(approval);
      await ensureActiveWallet();
      balances = await depositBalances(address);
      if (balances.allowance < units) {
        throw StateError(
          'USDC approval is not visible yet. Refresh before continuing.',
        );
      }
    }

    await evmWallet.switchToChain(depositChainId);
    await ensureActiveWallet();
    final data = depositForBurnCalldata(amount, address);
    // eth_call 是只读预执行，成功后仍需真实签名和网络确认。
    await _simulate(depositRpc, address, tokenMessenger, data);
    final record = PendingFundingAction(
      account: address,
      amount: normalizeFundingAmount(amount),
      kind: FundingActionKind.deposit,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: FundingActionStatus.unknown,
    );
    await _save(record);
    try {
      final hash = await evmWallet.sendEvmTransaction(
        to: tokenMessenger,
        data: data,
        chainId: depositChainId,
      );
      final submitted = record.copyWith(
        hash: hash,
        status: FundingActionStatus.submitted,
      );
      await _save(submitted);
      return submitted;
    } catch (error, stack) {
      AppDiagnostics.instance.error(
        'funding.bridge',
        error,
        stack,
        remote: false,
      );
      if (_isWalletRejection(error)) {
        await _save(record.copyWith(status: FundingActionStatus.reverted));
        rethrow;
      }
      throw FundingBridgeOutcomeUnknown(record, error);
    }
  }

  /// 结合账户模式、维护保证金可用量、HYPE Gas 和激活费计算可提金额。
  Future<WithdrawalQuote> withdrawalQuote(String address) async {
    final replies = await Future.wait<dynamic>([
      _transport.postInfo({'type': 'userAbstraction', 'user': address}),
      _transport.postInfo({'type': 'clearinghouseState', 'user': address}),
      _transport.postInfo({'type': 'spotClearinghouseState', 'user': address}),
      _rpc(hyperEvmRpc, 'eth_gasPrice', const []),
      _transport.postInfo({'type': 'allMids'}),
      _transport.postInfo({
        'type': 'preTransferCheck',
        'user': '0x2000000000000000000000000000000000000000',
        'source': address,
      }),
      _transport.postInfo({'type': 'usdcRouting'}),
    ]);
    final mode = replies[0] as String;
    final perp = _asMap(replies[1]);
    final spot = _asMap(replies[2]);
    final gasPrice = _quantity(replies[3]);
    final mids = _asMap(replies[4]);
    final activation = _asMap(replies[5]);
    final routing = _asMap(replies[6]);
    if (routing['withdrawalRoute'] != 'cctp') {
      throw StateError(
        'The official withdrawal route changed; verify funding on the official site.',
      );
    }
    if (activation['isSanctioned'] == true) {
      throw StateError(
        'This account cannot receive funds through the current route.',
      );
    }
    final shared = mode == 'unifiedAccount' || mode == 'portfolioMargin';
    final sourceDex = shared ? 'spot' : '';
    final hypePrice = Decimal.parse('${mids['HYPE']}');
    final gasHype = _weiToEther(gasPrice * BigInt.from(200000));
    final hypeBalance = _spotAvailable(spot, 'HYPE', shared);
    final gasInHype = hypeBalance >= Decimal.parse(gasHype);
    final initial = sourceDex == 'spot'
        ? _spotAvailable(spot, 'USDC', shared)
        : Decimal.parse('${perp['withdrawable'] ?? '0'}');
    final gasUsdc = gasInHype
        ? Decimal.zero
        : Decimal.parse(gasHype) * hypePrice;
    final fee = Decimal.parse('${activation['fee'] ?? '0'}');
    final available = _maxZero(initial - gasUsdc - fee).truncate(scale: 6);
    return WithdrawalQuote(
      account: address,
      sourceDex: sourceDex,
      gasHype: gasHype,
      gasUsdc: (Decimal.parse(gasHype) * hypePrice).toString(),
      gasInHype: gasInHype,
      activationFee: fee.toString(),
      available: available.toString(),
      at: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 签名前重新核对账户和费用；费用变高或计费方式变化时要求重新确认。
  Future<PendingFundingAction> submitWithdrawal({
    required WalletAdapter wallet,
    required WithdrawalQuote preview,
    required String amount,
    required Future<void> Function() ensureActiveWallet,
  }) async {
    final address = await wallet.getAddress();
    if (!sameFundingWallet(preview.account, address)) {
      throw StateError(
        'The active wallet changed. Reopen the withdrawal form.',
      );
    }
    await _assertNoPending(address);
    final fresh = await withdrawalQuote(address);
    final normalized = withdrawalAmount(amount, fresh.available);
    if (fresh.sourceDex != preview.sourceDex ||
        Decimal.parse(fresh.gasUsdc) > Decimal.parse(preview.gasUsdc) ||
        Decimal.parse(fresh.gasHype) > Decimal.parse(preview.gasHype) ||
        Decimal.parse(fresh.activationFee) >
            Decimal.parse(preview.activationFee) ||
        fresh.gasInHype != preview.gasInHype) {
      throw StateError('Fees changed. Review the refreshed withdrawal quote.');
    }
    await ensureActiveWallet();
    final nonce = DateTime.now().millisecondsSinceEpoch;
    final action = buildSendToEvmWithDataAction(
      address: address,
      amount: normalized,
      nonce: nonce,
      sourceDex: fresh.sourceDex,
    );
    final record = PendingFundingAction(
      account: address,
      amount: normalized,
      kind: FundingActionKind.withdraw,
      nonce: nonce,
      sourceDex: fresh.sourceDex,
      createdAt: nonce,
      status: FundingActionStatus.unknown,
    );
    await _save(record);
    var exchangeRejected = false;
    try {
      final signature = parseSignature(
        await wallet.signTypedData(buildSendToEvmWithDataTypedData(action)),
      );
      await ensureActiveWallet();
      final response = ExchangeResponse.fromJson(
        await _transport.postExchange({
          'action': action,
          'nonce': nonce,
          'signature': signature.toJson(),
        }) as Map<String, dynamic>,
      );
      if (response.isError) {
        await _save(record.copyWith(status: FundingActionStatus.reverted));
        exchangeRejected = true;
        throw StateError(
          response.errorMessage ?? 'The exchange rejected the withdrawal.',
        );
      }
      final submitted = record.copyWith(status: FundingActionStatus.submitted);
      await _save(submitted);
      return submitted;
    } catch (error, stack) {
      AppDiagnostics.instance.error(
        'funding.bridge',
        error,
        stack,
        remote: false,
      );
      if (_isWalletRejection(error)) {
        await _save(record.copyWith(status: FundingActionStatus.reverted));
        rethrow;
      }
      if (exchangeRejected) rethrow;
      throw FundingBridgeOutcomeUnknown(record, error);
    }
  }

  /// 按操作类型分别查源链回执、跨链索引和到账日志，证据不足时保留待核验状态。
  Future<PendingFundingAction> reconcile(PendingFundingAction record) async {
    PendingFundingAction next = record;
    if (record.kind == FundingActionKind.withdraw) {
      final response = await _rpcClient
          .get(
            Uri.https('dev.indexer.api.across.to', '/hyperliquid-transfers', {
              'direction': 'out',
              'user': record.account.toLowerCase(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw StateError('Withdrawal status is temporarily unavailable.');
      }
      final transfers = jsonDecode(response.body) as List<dynamic>;
      final hash = withdrawalTransaction(transfers, record);
      if (hash == null) return record;
      next = record.copyWith(hash: hash, status: FundingActionStatus.confirmed);
      await _save(next);
    }
    final hash = next.hash;
    if (hash == null) return next;
    final receipt = await _rpc(depositRpc, 'eth_getTransactionReceipt', [hash]);
    if (receipt == null) return next;
    final receiptMap = _asMap(receipt);
    if (!_receiptSucceeded(receiptMap)) {
      next = next.copyWith(status: FundingActionStatus.reverted);
      await _save(next);
      return next;
    }
    if (next.kind == FundingActionKind.approve) {
      next = next.copyWith(status: FundingActionStatus.confirmed);
      await _save(next);
      return next;
    }
    if (next.kind == FundingActionKind.withdraw) {
      if (receivedWithdrawal(
        (receiptMap['logs'] as List<dynamic>? ?? const []),
        next,
      )) {
        next = next.copyWith(status: FundingActionStatus.credited);
        await _save(next);
      }
      return next;
    }
    next = next.copyWith(status: FundingActionStatus.confirmed);
    await _save(next);
    final response = await _rpcClient
        .get(
          Uri.https('dev.indexer.api.across.to', '/hyperliquid-transfers', {
            'direction': 'in',
            'user': record.account.toLowerCase(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError(
        'Source transaction confirmed; destination credit is still pending verification.',
      );
    }
    final transfers = jsonDecode(response.body) as List<dynamic>;
    final updates = await _transport.postInfo({
      'type': 'userNonFundingLedgerUpdates',
      'user': record.account.toLowerCase(),
      'startTime': record.createdAt - 60000,
    }) as List<dynamic>;
    if (creditedDeposit(transfers, updates, record)) {
      next = next.copyWith(status: FundingActionStatus.credited);
      await _save(next);
    }
    return next;
  }

  /// 仅删除本地待核验记录，不撤销链上交易，也不重发资金请求。
  Future<void> resolveAfterManualCheck(PendingFundingAction record) async =>
      _remove(record);

  /// 授权交易也先模拟并保存 unknown，明确拒签才归为 reverted。
  Future<PendingFundingAction> _sendSourceTransaction({
    required EvmTransactionWallet wallet,
    required String address,
    required String amount,
    required FundingActionKind kind,
    required String data,
    required Future<void> Function() ensureActiveWallet,
  }) async {
    await _simulate(
      depositRpc,
      address,
      kind == FundingActionKind.approve ? depositUsdc : tokenMessenger,
      data,
    );
    final record = PendingFundingAction(
      account: address,
      amount: normalizeFundingAmount(amount),
      kind: kind,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: FundingActionStatus.unknown,
    );
    await _save(record);
    try {
      await ensureActiveWallet();
      final hash = await wallet.sendEvmTransaction(
        to: kind == FundingActionKind.approve ? depositUsdc : tokenMessenger,
        data: data,
        chainId: depositChainId,
      );
      final submitted = record.copyWith(
        hash: hash,
        status: FundingActionStatus.submitted,
      );
      await _save(submitted);
      return submitted;
    } catch (error, stack) {
      AppDiagnostics.instance.error(
        'funding.bridge',
        error,
        stack,
        remote: false,
      );
      if (_isWalletRejection(error)) {
        await _save(record.copyWith(status: FundingActionStatus.reverted));
        rethrow;
      }
      throw FundingBridgeOutcomeUnknown(record, error);
    }
  }

  Future<void> _simulate(
    String rpcUrl,
    String from,
    String to,
    String data,
  ) async {
    await _rpc(rpcUrl, 'eth_call', [
      {'from': from, 'to': to, 'data': data},
      'latest',
    ]);
  }

  /// 授权确认最多轮询两分钟；超时返回 null，由上层保留未知结果。
  Future<Map<String, dynamic>?> _waitForReceipt(String hash) async {
    final until = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(until)) {
      final value = await _rpc(depositRpc, 'eth_getTransactionReceipt', [hash]);
      if (value is Map) return _asMap(value);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  /// 统一 JSON-RPC 请求编号、HTTP 超时和节点错误转换，调用方决定是否保留资金状态。
  Future<dynamic> _rpc(String url, String method, List<dynamic> params) async {
    final response = await _rpcClient
        .post(
          Uri.parse(url),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': ++_rpcId,
            'method': method,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('RPC request failed with HTTP ${response.statusCode}.');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    if (payload['error'] != null) {
      throw StateError(
        '${payload['error']['message'] ?? 'RPC request failed.'}',
      );
    }
    return payload['result'];
  }

  bool _receiptSucceeded(Map<String, dynamic> receipt) =>
      '${receipt['status']}' == '0x1' || '${receipt['status']}' == '0x01';

  Future<void> _assertNoPending(String account) async {
    if ((await pendingFor(account)).isNotEmpty) {
      throw StateError(
        'Check or manually reconcile the previous funding request first.',
      );
    }
  }

  Future<List<PendingFundingAction>> _all() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List<dynamic>)
        .map(
          (item) => PendingFundingAction.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> _save(PendingFundingAction record) async {
    final all = await _all();
    final updated = [
      ...all.where(
        (item) =>
            item.account.toLowerCase() != record.account.toLowerCase() ||
            item.createdAt != record.createdAt,
      ),
      record,
    ];
    await _storage.write(
      key: _storageKey,
      value: jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> _remove(PendingFundingAction record) async {
    final remaining = (await _all())
        .where(
          (item) =>
              item.account.toLowerCase() != record.account.toLowerCase() ||
              item.createdAt != record.createdAt,
        )
        .toList();
    await _storage.write(
      key: _storageKey,
      value: jsonEncode(remaining.map((item) => item.toJson()).toList()),
    );
  }
}

class FundingBridgeOutcomeUnknown implements Exception {
  const FundingBridgeOutcomeUnknown(this.record, this.cause);
  final PendingFundingAction record;
  final Object cause;
  @override
  String toString() =>
      'Funding result is unknown; check status before retrying: $cause';
}

/// 只把可识别的用户拒签归为拒绝；其余异常由上层保守保留未知回报。
bool _isWalletRejection(Object error) {
  if (error is Map && (error['code'] == 4001 || error['code'] == '4001')) {
    return true;
  }
  final value = error.toString().toLowerCase();
  return value.contains('user rejected') ||
      value.contains('user denied') ||
      value.contains('request rejected') ||
      value.contains('cancelled by user');
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  throw const FormatException('The API returned an invalid object.');
}

BigInt _quantity(dynamic value) {
  if (value is! String || !value.startsWith('0x')) {
    throw const FormatException('The RPC returned an invalid hex quantity.');
  }
  return BigInt.parse(
    value.substring(2).isEmpty ? '0' : value.substring(2),
    radix: 16,
  );
}

String _weiToEther(BigInt value) =>
    Decimal.parse(value.toString()).shift(-18).toString();

/// 先扣除冻结量，统一账户还需取维护保证金后可用量的较小值。
Decimal _spotAvailable(Map<String, dynamic> spot, String coin, bool shared) {
  final balances = spot['balances'];
  if (balances is! List) return Decimal.zero;
  Map? balance;
  for (final item in balances.whereType<Map>()) {
    if (item['coin'] == coin) {
      balance = item;
      break;
    }
  }
  if (balance == null) return Decimal.zero;
  final available = _maxZero(
    Decimal.parse('${balance['total']}') - Decimal.parse('${balance['hold']}'),
  );
  if (!shared) return available;
  final token = balance['token'];
  final values = spot['tokenToAvailableAfterMaintenance'];
  if (values is! List) return Decimal.zero;
  for (final entry in values.whereType<List>()) {
    if (entry.length >= 2 && '${entry[0]}' == '$token') {
      final maintenance = Decimal.parse('${entry[1]}');
      return available < maintenance ? available : maintenance;
    }
  }
  return Decimal.zero;
}

Decimal _maxZero(Decimal value) => value < Decimal.zero ? Decimal.zero : value;

/// Hook 内部按 bytes24、uint32、uint32、address、uint32 拼接，不使用逐字段 32 字节填充。
String _hookData(String receiver) {
  const prefix = '636374702d666f7277617264';
  final bytes24 = prefix.padRight(48, '0');
  return '$bytes24'
      '00000000'
      '00000018'
      '${_validateAddress(receiver).substring(2).toLowerCase()}'
      '00000000';
}

String _addressBytes32(String value) =>
    _validateAddress(value).substring(2).toLowerCase().padLeft(64, '0');
String _addressWord(String value) => _addressBytes32(value);
String _addressTopic(String value) => '0x${_addressBytes32(value)}';
String _word(BigInt value) => value.toRadixString(16).padLeft(64, '0');

String _validateFundingHash(String value) {
  if (!RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(value)) {
    throw const FormatException('A valid transaction hash is required.');
  }
  return value;
}

String _validateAddress(String value) {
  if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(value)) {
    throw ArgumentError('A valid EVM address is required.');
  }
  return value;
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
