// Reown 连接与外部钱包适配。签名和链上交易请求交给外部钱包，App 接收回报。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:reown_appkit/reown_appkit.dart';

import 'evm_transaction_wallet.dart';

// 构建时通过 --dart-define 注入，普通 shell 环境变量不会自动进入 String.fromEnvironment。
const reownProjectId = String.fromEnvironment('REOWN_PROJECT_ID');
const _depositChainId = 421614;

/// 持有外部钱包连接弹层，保存的地址与当前连接会话分别管理。
class WalletConnectService {
  ReownAppKitModal? _modal;

  bool get isConfigured => reownProjectId.isNotEmpty;
  bool get isConnected => _modal?.isConnected ?? false;
  String? get address => _modal?.session?.getAddress('eip155');

  /// 建立 Reown 会话并请求签名、发交易及切链能力，返回 App 还依赖原生深链配置。
  Future<void> connect(BuildContext context) async {
    if (!isConfigured) {
      throw StateError('Set REOWN_PROJECT_ID to enable WalletConnect.');
    }
    final modal = _modal ??= ReownAppKitModal(
      context: context,
      projectId: reownProjectId,
      metadata: const PairingMetadata(
        name: 'Hyperliquid Testnet Terminal',
        description: 'A mobile testnet trading terminal',
        url: 'https://example.com',
        icons: [],
        redirect: Redirect(native: 'hyperliquidterminal://'),
      ),
      optionalNamespaces: {
        'eip155': RequiredNamespace.fromJson({
          'chains': ['eip155:421614'],
          'methods': [
            'eth_signTypedData_v4',
            'personal_sign',
            'eth_sendTransaction',
            'wallet_switchEthereumChain',
          ],
          'events': ['accountsChanged', 'chainChanged'],
        }),
      },
    );
    await modal.init();
    await modal.openModalView();
  }

  WalletAdapter walletAdapter() {
    final modal = _modal;
    final session = modal?.session;
    if (modal == null || session == null || !modal.isConnected) {
      throw StateError('Connect an external wallet first.');
    }
    final topic = session.topic;
    if (topic == null) {
      throw StateError('The external wallet session is missing its topic.');
    }
    return _ReownWalletAdapter(modal, topic);
  }
}

/// 实现与本地钱包相同的 SDK 接口，将请求封装成 WalletConnect JSON-RPC。
class _ReownWalletAdapter implements WalletAdapter, EvmTransactionWallet {
  const _ReownWalletAdapter(this._modal, this._topic);

  final ReownAppKitModal _modal;
  final String _topic;

  @override
  Future<String> getAddress() async {
    final address = _modal.session?.getAddress('eip155');
    if (address == null) {
      throw StateError('The connected wallet has no EVM address.');
    }
    return address;
  }

  @override
  Future<String> signTypedData(Map<String, dynamic> typedData) async {
    final address = await getAddress();
    final signature = await _modal.request(
      topic: _topic,
      chainId: 'eip155:421614',
      request: SessionRequestParams(
        method: 'eth_signTypedData_v4',
        params: [address, jsonEncode(typedData)],
      ),
    );
    if (signature is! String || !signature.startsWith('0x')) {
      throw StateError('The wallet returned an invalid signature.');
    }
    return signature;
  }

  /// 请求切换后再查询 eth_chainId，防止把钱包接受切换请求当作已经完成切链。
  @override
  Future<void> switchToChain(int chainId) async {
    if (chainId != _depositChainId) {
      throw StateError('Only Arbitrum Sepolia is enabled for funding.');
    }
    await _modal.request(
      topic: _topic,
      chainId: 'eip155:$chainId',
      request: SessionRequestParams(
        method: 'wallet_switchEthereumChain',
        params: [
          {'chainId': '0x${chainId.toRadixString(16)}'},
        ],
      ),
    );
    final current = await _modal.request(
      topic: _topic,
      chainId: 'eip155:$chainId',
      request: const SessionRequestParams(method: 'eth_chainId', params: []),
    );
    if (int.tryParse('$current'.replaceFirst('0x', ''), radix: 16) != chainId) {
      throw StateError('Switch the wallet to Arbitrum Sepolia first.');
    }
  }

  /// 返回值仅是交易哈希，到账是否完成由资金服务查询回执及目标账户证据。
  @override
  Future<String> sendEvmTransaction({
    required String to,
    required String data,
    required int chainId,
  }) async {
    await switchToChain(chainId);
    final from = await getAddress();
    final result = await _modal.request(
      topic: _topic,
      chainId: 'eip155:$chainId',
      request: SessionRequestParams(
        method: 'eth_sendTransaction',
        params: [
          {'from': from, 'to': to, 'data': data},
        ],
      ),
    );
    if (result is! String || !RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(result)) {
      throw StateError('The wallet did not return a transaction hash.');
    }
    return result;
  }
}
