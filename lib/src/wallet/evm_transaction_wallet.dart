// 补充 SDK WalletAdapter 之外的链上交易能力，供本地钱包和 Reown 钱包共同实现。

/// CCTP 存款需要切链与发送 EVM 交易，接口返回交易哈希供资金服务核验。
abstract interface class EvmTransactionWallet {
  Future<void> switchToChain(int chainId);

  Future<String> sendEvmTransaction({
    required String to,
    required String data,
    required int chainId,
  });
}

/// 带网络客户端的本地适配器在锁定钱包时释放资源。
abstract interface class DisposableWalletAdapter {
  void dispose();
}
