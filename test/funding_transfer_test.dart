// 内部划转的离线协议测试：验证六位 USDC 精度、签名字段和错误输入，未覆盖真实余额变化。

import 'package:flutter_test/flutter_test.dart';
import 'package:hyperliquid_testnet_terminal/src/funding/funding_transfer_service.dart';

void main() {
  test('formats exact USDC amount for the user-signed transfer action', () {
    expect(
      FundingTransferService.normalizeTransferAmount('12.340000'),
      '12.34',
    );
    expect(
      FundingTransferService.buildUsdClassTransferAction(
        amount: '12.34',
        toPerp: true,
        nonce: 123,
      ),
      {
        'type': 'usdClassTransfer',
        'hyperliquidChain': 'Testnet',
        'signatureChainId': '0xa4b1',
        'amount': '12.34',
        'toPerp': true,
        'nonce': 123,
      },
    );
  });

  test('rejects invalid or over-precision transfer amounts', () {
    expect(
      () => FundingTransferService.normalizeTransferAmount('0'),
      throwsArgumentError,
    );
    expect(
      () => FundingTransferService.normalizeTransferAmount('1e3'),
      throwsArgumentError,
    );
    expect(
      () => FundingTransferService.normalizeTransferAmount('1.0000001'),
      throwsArgumentError,
    );
  });
}
