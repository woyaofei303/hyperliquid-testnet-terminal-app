// 钱包记录、私钥安全存储与会话解锁。元数据和私钥分开存储，页面通过通知刷新活跃账户。

import '../diagnostics/diagnostic_http_client.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:local_auth/local_auth.dart';
import 'package:wallet/wallet.dart';
import 'package:web3dart/web3dart.dart';

import 'evm_transaction_wallet.dart';
import 'key_derivation.dart';

enum WalletKind { local, external }

/// 页面可见的钱包元数据，序列化内容不包含私钥或助记词。
class WalletRecord {
  const WalletRecord({
    required this.id,
    required this.name,
    required this.address,
    required this.kind,
  });

  final String id;
  final String name;
  final String address;
  final WalletKind kind;

  factory WalletRecord.fromJson(Map<String, dynamic> json) => WalletRecord(
    id: json['id'] as String,
    name: json['name'] as String,
    address: json['address'] as String,
    kind: WalletKind.values.byName(json['kind'] as String),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'kind': kind.name,
  };
}

/// 私钥由系统安全存储插件保存，已解锁的签名适配器仅缓存于进程内。
class WalletVault extends ChangeNotifier {
  WalletVault({
    FlutterSecureStorage? storage,
    LocalAuthentication? authentication,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _authentication = authentication ?? LocalAuthentication();

  static const _walletsKey = 'wallets.v1';
  static const _activeKey = 'wallets.active';
  final FlutterSecureStorage _storage;
  final LocalAuthentication _authentication;
  final Map<String, WalletAdapter> _unlocked = {};

  Future<List<WalletRecord>> listWallets() async {
    final value = await _storage.read(key: _walletsKey);
    if (value == null) return const [];
    final decoded = jsonDecode(value) as List<dynamic>;
    return decoded
        .map((item) => WalletRecord.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<WalletRecord?> activeWallet() async {
    final active = await _storage.read(key: _activeKey);
    if (active == null) return null;
    for (final wallet in await listWallets()) {
      if (wallet.id == active) return wallet;
    }
    return null;
  }

  /// 生成 12 词英文助记词，保存推导出的私钥，助记词只返回给当前备份弹层。
  Future<({WalletRecord wallet, String mnemonic})> createWallet(
    String name,
  ) async {
    final mnemonic = Mnemonic.generate(
      Language.english,
      length: MnemonicLength.words12,
    );
    final key = deriveEthereumPrivateKeyFromSeed(mnemonic.seed);
    final wallet = await _saveWallet(name: name, privateKey: key);
    return (wallet: wallet, mnemonic: mnemonic.sentence);
  }

  /// 校验助记词并按固定派生路径恢复账户，保存方式与新建钱包一致。
  Future<WalletRecord> importMnemonic({
    required String name,
    required String phrase,
  }) async {
    final mnemonic = Mnemonic.fromSentence(
      phrase.trim().toLowerCase(),
      Language.english,
    );
    final key = deriveEthereumPrivateKeyFromSeed(mnemonic.seed);
    return _saveWallet(name: name, privateKey: key);
  }

  /// 补齐 0x 前缀后交给密码库校验并推导地址，不把输入私钥暴露给页面记录。
  Future<WalletRecord> importPrivateKey({
    required String name,
    required String privateKey,
  }) async {
    final normalized = privateKey.trim().startsWith('0x')
        ? privateKey.trim()
        : '0x${privateKey.trim()}';
    final wallet = EthPrivateKey.fromHex(normalized);
    return _saveWallet(
      name: name,
      privateKey: normalized,
      address: wallet.address.eip55With0x,
    );
  }

  /// 按地址阻止重复导入，先写私钥，再写记录并设为活跃账户；多次存储调用并非事务。
  Future<WalletRecord> _saveWallet({
    required String name,
    required String privateKey,
    String? address,
  }) async {
    final signer = PrivateKeyWalletAdapter(privateKey);
    final derivedAddress = address ?? await signer.getAddress();
    final existing = await listWallets();
    if (existing.any(
      (wallet) => wallet.address.toLowerCase() == derivedAddress.toLowerCase(),
    )) {
      throw StateError('This wallet is already saved on this device.');
    }
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final record = WalletRecord(
      id: id,
      name: name.trim().isEmpty ? 'Wallet ${existing.length + 1}' : name.trim(),
      address: derivedAddress,
      kind: WalletKind.local,
    );
    await _storage.write(key: 'wallet.secret.$id', value: privateKey);
    await _writeWallets([...existing, record]);
    _clearUnlocked();
    await _storage.write(key: _activeKey, value: id);
    notifyListeners();
    return record;
  }

  /// 外部钱包只保存地址和名称，签名能力来自 Reown 当前会话。
  Future<void> saveExternalWallet(
    String address, {
    String name = 'WalletConnect',
  }) async {
    final existing = await listWallets();
    final normalized = address.toLowerCase();
    final record = existing
        .where((wallet) => wallet.address.toLowerCase() == normalized)
        .firstOrNull;
    if (record != null) {
      _clearUnlocked();
      await _storage.write(key: _activeKey, value: record.id);
      notifyListeners();
      return;
    }
    final id =
        'external-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final external = WalletRecord(
      id: id,
      name: name,
      address: address,
      kind: WalletKind.external,
    );
    _clearUnlocked();
    await _writeWallets([...existing, external]);
    await _storage.write(key: _activeKey, value: id);
    notifyListeners();
  }

  /// 切换活跃账户之前清空已解锁适配器，避免沿用之前账户的会话解锁。
  Future<void> setActive(String id) async {
    if (!(await listWallets()).any((wallet) => wallet.id == id)) {
      throw StateError('Wallet not found.');
    }
    _clearUnlocked();
    await _storage.write(key: _activeKey, value: id);
    notifyListeners();
  }

  /// 每次本地会话首次签名请求设备认证；拒绝认证抛错，外部钱包返回 null 交由 Reown。
  Future<WalletAdapter?> unlockActive() async {
    final wallet = await activeWallet();
    if (wallet == null || wallet.kind != WalletKind.local) return null;
    var adapter = _unlocked[wallet.id];
    if (adapter == null) {
      final authenticated = await _authentication.authenticate(
        localizedReason: 'Unlock your local trading wallet',
      );
      if (!authenticated) throw StateError('Wallet unlock was cancelled.');
      final privateKey = await _storage.read(key: 'wallet.secret.${wallet.id}');
      if (privateKey == null) {
        throw StateError('Wallet key is missing from secure storage.');
      }
      adapter = _LocalWalletAdapter(privateKey);
      _unlocked[wallet.id] = adapter;
    }
    return adapter;
  }

  Future<void> lock() async => _clearUnlocked();

  /// 移除设备记录和本地私钥；移除活跃钱包时选择剩余的第一个账户。
  Future<void> remove(String id) async {
    final wallets = await listWallets();
    await _writeWallets(wallets.where((wallet) => wallet.id != id).toList());
    await _storage.delete(key: 'wallet.secret.$id');
    final adapter = _unlocked.remove(id);
    if (adapter is DisposableWalletAdapter) {
      (adapter as DisposableWalletAdapter).dispose();
    }
    if (await _storage.read(key: _activeKey) == id) {
      final remaining = wallets.where((wallet) => wallet.id != id).firstOrNull;
      if (remaining == null) {
        await _storage.delete(key: _activeKey);
      } else {
        await _storage.write(key: _activeKey, value: remaining.id);
      }
    }
    notifyListeners();
  }

  Future<void> _writeWallets(List<WalletRecord> wallets) => _storage.write(
    key: _walletsKey,
    value: jsonEncode(wallets.map((wallet) => wallet.toJson()).toList()),
  );

  /// 释放客户端并清空适配器引用，Dart 层不承诺主动抹除内存中的字符串字节。
  void _clearUnlocked() {
    for (final adapter in _unlocked.values) {
      if (adapter is DisposableWalletAdapter) {
        (adapter as DisposableWalletAdapter).dispose();
      }
    }
    _unlocked.clear();
  }
}

/// 交易所 typed data 签名交给 SDK，链上交易交给 web3dart；资金链固定为 Arbitrum Sepolia。
class _LocalWalletAdapter
    implements WalletAdapter, EvmTransactionWallet, DisposableWalletAdapter {
  _LocalWalletAdapter(String privateKey)
    : _signer = PrivateKeyWalletAdapter(privateKey),
      _credentials = EthPrivateKey.fromHex(privateKey);

  final PrivateKeyWalletAdapter _signer;
  final EthPrivateKey _credentials;
  Web3Client? _evmClient;

  @override
  Future<String> getAddress() => _signer.getAddress();

  @override
  Future<String> signTypedData(Map<String, dynamic> typedData) =>
      _signer.signTypedData(typedData);

  @override
  Future<void> switchToChain(int chainId) async {
    if (chainId != 421614) {
      throw StateError('Only Arbitrum Sepolia is enabled for funding.');
    }
  }

  @override
  Future<String> sendEvmTransaction({
    required String to,
    required String data,
    required int chainId,
  }) async {
    await switchToChain(chainId);
    final client = _evmClient ??= Web3Client(
      'https://sepolia-rollup.arbitrum.io/rpc',
      DiagnosticHttpClient(),
    );
    final hash = await client.sendTransaction(
      _credentials,
      Transaction(
        to: EthereumAddress.fromHex(to),
        data: hexToBytes(data),
        value: EtherAmount.zero(),
        gasPrice: await client.getGasPrice(),
      ),
      chainId: chainId,
    );
    return hash;
  }

  @override
  void dispose() {
    _evmClient?.dispose();
    _evmClient = null;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
