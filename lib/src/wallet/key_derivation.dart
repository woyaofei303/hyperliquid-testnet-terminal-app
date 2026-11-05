// 从助记词生成的 seed 推导第一个以太坊账户私钥，路径固定为 m/44'/60'/0'/0/0。

import 'dart:typed_data';

import 'package:bip32_keys/bip32_keys.dart';

/// 输入 BIP-39 seed 字节，输出带 0x 的私钥。学习和测试仅使用公开测试向量。
String deriveEthereumPrivateKeyFromSeed(List<int> seed) {
  final bytes = Bip32Keys.fromSeed(Uint8List.fromList(seed))
      .derivePath("m/44'/60'/0'/0/0")
      .private!;
  return '0x${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
}
