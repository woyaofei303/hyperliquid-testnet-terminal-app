// 纯数据测试：USDC 精度、CCTP ABI 编码、提款签名对象和到账证据匹配；不会请求签名或发起链上交易。

import 'package:flutter_test/flutter_test.dart';
import 'package:hyperliquid_testnet_terminal/src/funding/funding_bridge_service.dart';

void main() {
  test('CCTP deposits enforce the Web USDC limits and six decimals', () {
    expect(fundingAmountUnits('5'), BigInt.from(5000000));
    expect(fundingAmountUnits('5.000001'), BigInt.from(5000001));
    expect(() => fundingAmountUnits('4.99'), throwsArgumentError);
    expect(() => fundingAmountUnits('10000000'), throwsArgumentError);
    expect(() => fundingAmountUnits('5.0000001'), throwsArgumentError);
  });

  test('approval calldata uses the fixed USDC and TokenMessenger shape', () {
    expect(
      approveUsdcCalldata('5'),
      '0x095ea7b3'
      '0000000000000000000000008fe6b999dc680ccfdd5bf7eb0974218be2542daa'
      '00000000000000000000000000000000000000000000000000000000004c4b40',
    );
  });

  test('CCTP hook payload is bound to this receiver and domain 19', () {
    const receiver = '0x1111111111111111111111111111111111111111';
    final call = depositForBurnCalldata('5', receiver);
    expect(call.startsWith('0x'), isTrue);
    expect(
      call,
      contains(
        '0000000000000000000000000000000000000000000000000000000000000013',
      ),
    );
    expect(call, contains('1111111111111111111111111111111111111111'));
    expect(
      call,
      contains('636374702d666f727761726400000000000000000000000000000000'),
    );
  });

  test(
    'withdraw action and typed data use Hyperliquid Testnet CCTP fields',
    () {
      const address = '0x2222222222222222222222222222222222222222';
      final action = buildSendToEvmWithDataAction(
        address: address,
        amount: '10',
        nonce: 1234,
      );
      expect(action, {
        'type': 'sendToEvmWithData',
        'signatureChainId': '0xa4b1',
        'hyperliquidChain': 'Testnet',
        'token': 'USDC',
        'amount': '10',
        'sourceDex': '',
        'destinationRecipient': address,
        'addressEncoding': 'hex',
        'destinationChainId': 3,
        'gasLimit': 200000,
        'data': '0x',
        'nonce': 1234,
      });
      final typed = buildSendToEvmWithDataTypedData(action);
      expect(typed['primaryType'], 'HyperliquidTransaction:SendToEvmWithData');
      expect(
        ((typed['types'] as Map)['HyperliquidTransaction:SendToEvmWithData']
                as List)
            .map((field) => (field as Map)['name'])
            .toList(),
        [
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
        ],
      );
    },
  );

  test('withdrawals subtract the fee and enforce amount precision', () {
    expect(withdrawalAmount('1', '3'), '1');
    expect(() => withdrawalAmount('0.39', '3'), throwsArgumentError);
    expect(() => withdrawalAmount('1.0000001', '3'), throwsArgumentError);
    expect(() => withdrawalAmount('3.1', '3'), throwsArgumentError);
  });

  test('funding receipt matchers require nonce, chain and receiver evidence', () {
    const record = PendingFundingAction(
      account: '0x1111111111111111111111111111111111111111',
      amount: '1',
      kind: FundingActionKind.deposit,
      nonce: 55,
      createdAt: 100,
      status: FundingActionStatus.submitted,
      hash:
          '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(
      creditedDeposit(
        [
          {'depositTxnRef': record.hash, 'originChainId': 421614, 'nonce': 55},
        ],
        [
          {
            'delta': {
              'type': 'send',
              'destination': record.account,
              'nonce': 55,
              'token': 'USDC:0x1234',
            },
          },
        ],
        record,
      ),
      isTrue,
    );
    expect(
      creditedDeposit(
        [
          {'depositTxnRef': record.hash, 'originChainId': 42161, 'nonce': 55},
        ],
        const [],
        record,
      ),
      isFalse,
    );
  });

  test('CCTP hook packs uint32 fields as four-byte values', () {
    final call = depositForBurnCalldata(
      '5',
      '0x1111111111111111111111111111111111111111',
    );
    expect(call.substring(2, 10), '779b432d');
    expect(
      call,
      contains(
        '636374702d666f7277617264000000000000000000000000'
        '00000000'
        '00000018'
        '1111111111111111111111111111111111111111'
        '00000000',
      ),
    );
  });

  test('a 0.4 USDC withdrawal receipt can verify its 0.2 USDC net amount', () {
    const record = PendingFundingAction(
      account: '0x1111111111111111111111111111111111111111',
      amount: '0.4',
      kind: FundingActionKind.withdraw,
      createdAt: 100,
      nonce: 100,
      sourceDex: '',
      status: FundingActionStatus.confirmed,
    );
    expect(
      receivedWithdrawal([
        {
          'address': depositUsdc,
          'topics': [
            '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
            '0x${'0' * 64}',
            '0x0000000000000000000000001111111111111111111111111111111111111111',
          ],
          'data': '0x30d40',
        },
      ], record),
      isTrue,
    );
  });

  test(
    'confirmed withdrawals stay pending until Arbitrum credit is verified',
    () {
      const record = PendingFundingAction(
        account: '0x1111111111111111111111111111111111111111',
        amount: '1',
        kind: FundingActionKind.withdraw,
        createdAt: 100,
        nonce: 100,
        sourceDex: '',
        status: FundingActionStatus.confirmed,
      );
      expect(isFundingActionPending(record), isTrue);
      expect(
        isFundingActionPending(
          record.copyWith(status: FundingActionStatus.credited),
        ),
        isFalse,
      );
    },
  );

  test('funding records reject malformed source transaction hashes', () {
    const record = PendingFundingAction(
      account: '0x1111111111111111111111111111111111111111',
      amount: '5',
      kind: FundingActionKind.deposit,
      createdAt: 100,
      status: FundingActionStatus.unknown,
    );
    expect(
      () => record.copyWith(hash: 'not-a-transaction-hash'),
      throwsFormatException,
    );
  });

  test('funding signer must remain on the address shown in confirmation', () {
    expect(
      sameFundingWallet(
        '0xAbCd000000000000000000000000000000001234',
        '0xabcd000000000000000000000000000000001234',
      ),
      isTrue,
    );
    expect(
      sameFundingWallet(
        '0xabcd000000000000000000000000000000001234',
        '0xeeee000000000000000000000000000000005678',
      ),
      isFalse,
    );
  });
}
