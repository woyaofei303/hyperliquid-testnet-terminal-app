// 使用公开测试向量核对 BIP-39 seed 到以太坊地址的派生；测试中的固定密钥不能用于保存任何资产。

import 'package:flutter_test/flutter_test.dart';
import 'package:bip39_mnemonic/bip39_mnemonic.dart';
import 'package:hyperliquid_testnet_terminal/src/wallet/key_derivation.dart';

void main() {
  test('BIP39 Ethereum derivation matches the standard vector', () {
    const phrase =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    // Public reference vector only; never fund or reuse this key.
    final seed = Mnemonic.fromSentence(phrase, Language.english).seed;
    expect(phrase.split(' ').length, 12);
    expect(
      deriveEthereumPrivateKeyFromSeed(seed),
      '0x1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727',
    );
  });
}
