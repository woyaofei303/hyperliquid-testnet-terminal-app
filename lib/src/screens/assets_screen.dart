// 资产总览、钱包管理和资金记录页面。用户操作在此确认，具体签名与核验由 service 执行。

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/diagnostic_http_client.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:decimal/decimal.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';

import '../app/theme.dart';
import '../market/coin_icon.dart';
import '../funding/funding_bridge_service.dart';
import '../funding/funding_transfer_service.dart';
import '../wallet/wallet_connect_service.dart';
import '../wallet/wallet_vault.dart';

/// 同一组件根据路由参数显示总览、钱包管理或待核验资金记录。
enum AssetPage { overview, wallets, activity }

/// 协调设备钱包、交易所账户和链上资金服务，余额查询均使用只读接口。
class AssetsScreen extends StatefulWidget {
  const AssetsScreen({
    super.key,
    required this.walletVault,
    required this.walletConnect,
    required this.english,
    this.page = AssetPage.overview,
  });

  final AssetPage page;
  final WalletVault walletVault;
  final WalletConnectService walletConnect;
  final bool english;

  @override
  State<AssetsScreen> createState() => _AssetsScreenState();
}

class _AssetsScreenState extends State<AssetsScreen> {
  final _bridge = FundingBridgeService();
  final _funding = FundingTransferService();
  List<WalletRecord> _wallets = const [];
  List<PendingFundingTransfer> _pendingTransfers = const [];
  List<PendingFundingAction> _pendingBridgeActions = const [];
  String? _activeId;
  bool _working = false;
  bool _hidden = false;
  bool _tokensOpen = true;
  int _refreshId = 0;
  PortfolioPeriod? _month;
  List<SpotBalance>? _balances;
  String? _perpEquity;
  bool _balanceError = false;

  @override
  void initState() {
    super.initState();
    widget.walletVault.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    widget.walletVault.removeListener(_refresh);
    _bridge.dispose();
    _funding.dispose();
    super.dispose();
  }

  /// 刷新序号隔离旧回包，切换钱包先清空旧余额；三个账户查询独立成功或失败。
  Future<void> _refresh() async {
    final id = ++_refreshId;
    final wallets = await widget.walletVault.listWallets();
    final active = await widget.walletVault.activeWallet();
    final pending = active == null
        ? const <PendingFundingTransfer>[]
        : await _funding.pendingFor(active.address);
    final pendingBridge = active == null
        ? const <PendingFundingAction>[]
        : await _bridge.pendingFor(active.address);
    if (!mounted || id != _refreshId) return;
    setState(() {
      if (_activeId != active?.id) {
        _month = null;
        _balances = null;
        _perpEquity = null;
      }
      _wallets = wallets;
      _activeId = active?.id;
      _pendingTransfers = pending;
      _pendingBridgeActions = pendingBridge;
      _balanceError = false;
    });
    if (active == null || widget.page != AssetPage.overview) return;
    final info = diagnosticInfo();
    Future<void> read<T>(Future<T> request, void Function(T) accept) async {
      try {
        final value = await request;
        if (mounted && id == _refreshId) setState(() => accept(value));
      } catch (error, stack) {
        AppDiagnostics.instance.error('assets.balance', error, stack);
        if (mounted && id == _refreshId) setState(() => _balanceError = true);
      }
    }

    try {
      await Future.wait([
        read(
          info.portfolio(active.address),
          (v) => _month = v.periods['month'],
        ),
        read(
          info.spotClearinghouseState(active.address),
          (v) => _balances = v.balances,
        ),
        read(
          info.clearinghouseState(active.address),
          (v) => _perpEquity = v.accountValue,
        ),
      ]);
    } finally {
      info.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final english = widget.english;
    final active = _wallets
        .where((wallet) => wallet.id == _activeId)
        .firstOrNull;
    if (widget.page != AssetPage.overview) {
      final wallets = widget.page == AssetPage.wallets;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            wallets
                ? (english ? 'Wallet management' : '钱包管理')
                : (english ? 'Funding activity' : '资金记录'),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            if (wallets) ...[
              _SectionTitle(
                title: english ? 'Wallets' : '钱包',
                trailing: '${_wallets.length}',
              ),
              const SizedBox(height: 8),
              if (_wallets.isNotEmpty)
                ..._wallets.map(
                  (wallet) => _WalletCard(
                    wallet: wallet,
                    active: wallet.id == _activeId,
                    english: english,
                    onSelect: () => widget.walletVault.setActive(wallet.id),
                    onRemove: () => _removeWallet(wallet),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.add,
                      label: english ? 'Create wallet' : '创建内置钱包',
                      onPressed: _working ? null : _createWallet,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ActionButton(
                      icon: Icons.file_download_outlined,
                      label: english ? 'Import wallet' : '导入钱包',
                      onPressed: _working ? null : _importWallet,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _ActionButton(
                icon: Icons.link,
                label: widget.walletConnect.isConfigured
                    ? (english ? 'Connect external wallet' : '连接外部钱包')
                    : (english
                          ? 'WalletConnect setup required'
                          : '外部钱包需配置 Project ID'),
                onPressed: !_working && widget.walletConnect.isConfigured
                    ? _connectExternal
                    : null,
                outlined: true,
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      color: AppColors.accent,
                      size: 18,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        english
                            ? 'Local keys stay in the device Keychain or Android Keystore. A device passcode or biometrics is requested before signing.'
                            : '内置钱包密钥只保存在本机 Keychain / Android Keystore。签名前需要设备密码或生物识别解锁。',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ] else ...[
              if (_pendingTransfers.isEmpty && _pendingBridgeActions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  child: Text(
                    english
                        ? 'No funding operations awaiting verification'
                        : '暂无待核验的资金操作',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final pending in _pendingTransfers)
                _PendingTransferCard(
                  pending: pending,
                  english: english,
                  onVerified: () => _resolveTransfer(pending),
                ),
              for (final pending in _pendingBridgeActions)
                _PendingBridgeCard(
                  pending: pending,
                  english: english,
                  onCheck: () => _reconcileBridge(pending),
                  onClear: () => _resolveBridge(pending),
                ),
              const SizedBox(height: 10),
              Text(
                english
                    ? 'CCTP status is checked against Arbitrum and Hyperliquid testnet data. Unknown results stay locked until you verify them; the app never resends automatically.'
                    : 'CCTP 状态会核对 Arbitrum 与 Hyperliquid 测试网数据。结果不明时需要先人工核验，App 不会自动重发。',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ],
        ),
      );
    }
    final values = _history(_month?.accountValueHistory);
    final pnl = _history(_month?.pnlHistory);
    final gain = pnl.length < 2 ? null : pnl.last - pnl.first;
    final nonzero =
        _balances
            ?.where((b) => Decimal.tryParse(b.total) != Decimal.zero)
            .toList() ??
        [];
    String amount(num? n) => _hidden
        ? '••••'
        : n == null
        ? '—'
        : NumberFormat('#,##0.##').format(n);
    final cash = _balances?.where((b) => b.coin == 'USDC').firstOrNull;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  english ? 'Portfolio value' : '总资产估值',
                  style: const TextStyle(color: AppColors.muted),
                ),
                IconButton(
                  tooltip: _hidden
                      ? (english ? 'Show balances' : '显示金额')
                      : (english ? 'Hide balances' : '隐藏金额'),
                  onPressed: () => setState(() => _hidden = !_hidden),
                  icon: Icon(
                    _hidden
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: english ? 'Funding activity' : '资金记录',
                  icon: Badge(
                    isLabelVisible:
                        _pendingTransfers.isNotEmpty ||
                        _pendingBridgeActions.isNotEmpty,
                    child: const Icon(Icons.history, size: 21),
                  ),
                  onPressed: () => _openPage(AssetPage.activity),
                ),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(
                    amount(values.lastOrNull),
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 7, bottom: 7),
                  child: Text('USD'),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    active == null
                        ? (english
                              ? 'Connect a wallet to view assets'
                              : '连接钱包后查看资产')
                        : '${english ? 'Monthly P&L' : '近一月盈亏'}  ${amount(gain)} USD',
                    style: TextStyle(
                      color: gain == null || _hidden
                          ? AppColors.muted
                          : gain < 0
                          ? AppColors.negative
                          : AppColors.positive,
                    ),
                  ),
                ),
                if (!_hidden && values.length > 1)
                  SizedBox(
                    width: 76,
                    height: 28,
                    child: CustomPaint(painter: _BalanceTrend(values)),
                  ),
              ],
            ),
            if (_balanceError)
              TextButton(
                onPressed: _refresh,
                child: Text(
                  english
                      ? 'Some balances unavailable · retry'
                      : '部分资产数据未更新 · 重试',
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                for (final item in [
                  (Icons.south_west, english ? 'Deposit' : '存款', _depositFunds),
                  (
                    Icons.north_east,
                    english ? 'Withdraw' : '提款',
                    _withdrawFunds,
                  ),
                  (
                    Icons.swap_horiz,
                    english ? 'Transfer' : '划转',
                    _transferFunds,
                  ),
                  (
                    Icons.account_balance_wallet_outlined,
                    english ? 'Wallets' : '钱包',
                    () => _openPage(AssetPage.wallets),
                  ),
                ])
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _working ? null : item.$3,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          children: [
                            CircleAvatar(
                              radius: 22,
                              backgroundColor: AppColors.surface,
                              foregroundColor: AppColors.accent,
                              child: Icon(item.$1, size: 22),
                            ),
                            const SizedBox(height: 6),
                            Text(item.$2),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 12),
            _SectionTitle(title: english ? 'Accounts' : '资产组合'),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final item in [
                  (
                    english ? 'Spot USDC' : '现货 USDC',
                    amount(
                      _balances == null
                          ? null
                          : double.tryParse(cash?.total ?? '0'),
                    ),
                  ),
                  (
                    english ? 'Perp equity · USD' : '永续权益 · USD',
                    amount(double.tryParse(_perpEquity ?? '')),
                  ),
                ])
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(right: 5),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.panel,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.$1,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            item.$2,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (active != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(english ? 'Tokens' : '代币'),
                trailing: Icon(
                  _tokensOpen ? Icons.expand_less : Icons.expand_more,
                ),
                onTap: () => setState(() => _tokensOpen = !_tokensOpen),
              ),
              if (_tokensOpen && nonzero.isEmpty)
                Text(
                  _balances == null
                      ? (english ? 'Balance unavailable' : '尚无余额数据')
                      : (english ? 'No token balances' : '暂无代币持仓'),
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              if (_tokensOpen)
                for (final token in nonzero)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CoinIcon(token.coin),
                    title: Text(token.coin),
                    trailing: Text(_hidden ? '••••' : token.total),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  /// 从总览进入子页面，返回时重新读取钱包与资金记录。
  Future<void> _openPage(AssetPage page) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AssetsScreen(
          walletVault: widget.walletVault,
          walletConnect: widget.walletConnect,
          english: widget.english,
          page: page,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  /// 设备内生成账户后立即展示恢复助记词，页面不保存助记词到普通偏好设置。
  Future<void> _createWallet() async {
    final name = await _nameDialog();
    if (name == null) return;
    await _run(() async {
      final result = await widget.walletVault.createWallet(name);
      if (!mounted) return;
      await _showRecoveryPhrase(result.wallet, result.mnemonic);
      await _refresh();
    });
  }

  /// 弹层结果包含私密文本，仅传给 WalletVault，避免写入日志。
  Future<void> _importWallet() async {
    final result =
        await showDialog<({String name, String secret, bool mnemonic})>(
          context: context,
          builder: (context) => _ImportWalletDialog(english: widget.english),
        );
    if (result == null) return;
    await _run(() async {
      final wallet = result.mnemonic
          ? await widget.walletVault.importMnemonic(
              name: result.name,
              phrase: result.secret,
            )
          : await widget.walletVault.importPrivateKey(
              name: result.name,
              privateKey: result.secret,
            );
      await _refresh();
      if (mounted) {
        _notice(
          widget.english ? '${wallet.name} imported' : '已导入 ${wallet.name}',
        );
      }
    });
  }

  /// 连接完成后保存外部地址，实际签名会在后续操作时通过 Reown 请求。
  Future<void> _connectExternal() async {
    await _run(() async {
      await widget.walletConnect.connect(context);
      final address = widget.walletConnect.address;
      if (address == null) return;
      await widget.walletVault.saveExternalWallet(address);
      await _refresh();
    });
  }

  /// 删除前需确认，确认内容对应的是本机密钥与元数据。
  Future<void> _removeWallet(WalletRecord wallet) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(widget.english ? 'Remove wallet?' : '移除钱包？'),
        content: Text(
          widget.english
              ? 'The encrypted local key will be deleted from this device.'
              : '此设备上加密保存的本地私钥将被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.english ? 'Keep' : '保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.english ? 'Remove' : '移除'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    await _run(() => widget.walletVault.remove(wallet.id));
    await _refresh();
  }

  Future<String?> _nameDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(widget.english ? 'Name this wallet' : '为钱包命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: widget.english ? 'Optional' : '可选',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.english ? 'Cancel' : '取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(widget.english ? 'Continue' : '继续'),
          ),
        ],
      ),
    );
    controller.dispose();
    return name;
  }

  /// 助记词仅在此次新建流程中展示，复制动作由用户主动触发。
  Future<void> _showRecoveryPhrase(WalletRecord wallet, String phrase) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(
          widget.english ? 'Back up your recovery phrase' : '备份恢复助记词',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.english
                  ? 'Write these words down and keep them offline. They will not be shown again.'
                  : '请抄写并离线保存；关闭后不会再次显示。',
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            SelectableText(
              phrase,
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: 16,
                height: 1.7,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: phrase)),
              icon: const Icon(Icons.copy, size: 16),
              label: Text(widget.english ? 'Copy phrase' : '复制助记词'),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.english ? 'I saved it' : '已妥善保存'),
          ),
        ],
      ),
    );
    if (mounted) {
      _notice(widget.english ? '${wallet.name} created' : '已创建 ${wallet.name}');
    }
  }

  /// 先只读查源链余额，再让用户填写并确认金额，之后请求签名和 CCTP 提交。
  Future<void> _depositFunds() async {
    await _run(() async {
      final active = await _activeFundingWallet();
      final balances = await _bridge.depositBalances(active.address);
      if (balances.gasWei == BigInt.zero) {
        throw StateError('Arbitrum Sepolia ETH is required for gas.');
      }
      final amount = await _fundingAmountDialog(
        title: widget.english ? 'Deposit testnet USDC' : '存入测试网 USDC',
        details: widget.english
            ? 'Arbitrum Sepolia balance: ${_usdc(balances.usdc)} USDC\nAt least 5 USDC. Up to 0.2 USDC CCTP fee, plus Arbitrum gas.'
            : 'Arbitrum Sepolia 余额：${_usdc(balances.usdc)} USDC\n最低 5 USDC；CCTP 费用上限 0.2 USDC，另需 Arbitrum Gas。',
        minimum: '5',
      );
      if (!mounted || amount == null) return;
      final units = fundingAmountUnits(amount);
      if (balances.usdc < units) {
        throw StateError('Arbitrum Sepolia USDC balance is too low.');
      }
      if (!await _confirmFunding(
        widget.english ? 'Confirm CCTP deposit' : '确认 CCTP 存款',
        widget.english
            ? '$amount USDC will be burned on Arbitrum Sepolia and sent to ${active.address}. The wallet may request an approval and a deposit signature.'
            : '将从 Arbitrum Sepolia 销毁 $amount USDC 并发送到 ${active.address}。钱包可能会分别请求授权和存款签名。',
      )) {
        return;
      }
      final signer = await _fundingSigner(active);
      await _bridge.submitDeposit(
        wallet: signer,
        expectedAddress: active.address,
        amount: amount,
        ensureActiveWallet: () => _ensureActiveFundingWallet(active),
      );
      await _refresh();
      _notice(
        widget.english
            ? 'Deposit submitted. Check status before taking further action.'
            : '存款请求已提交。请先核验状态，再进行后续操作。',
      );
    });
  }

  /// 预览可提余额和费用，用户确认后把快照交给服务再次检查再提交。
  Future<void> _withdrawFunds() async {
    await _run(() async {
      final active = await _activeFundingWallet();
      final quote = await _bridge.withdrawalQuote(active.address);
      final gas = quote.gasInHype
          ? '${quote.gasHype} HYPE'
          : '~${quote.gasUsdc} USDC';
      final amount = await _fundingAmountDialog(
        title: widget.english ? 'Withdraw testnet USDC' : '提取测试网 USDC',
        details: widget.english
            ? 'Available: ${quote.available} USDC\nDestination fee: $withdrawalFee USDC · Network gas: $gas · Activation fee: ${quote.activationFee} USDC'
            : '可提取：${quote.available} USDC\n目标链费用：$withdrawalFee USDC · 网络 Gas：$gas · 激活费用：${quote.activationFee} USDC',
        minimum: '0.4',
      );
      if (!mounted || amount == null) return;
      final normalized = withdrawalAmount(amount, quote.available);
      final received =
          (Decimal.parse(normalized) - Decimal.parse(withdrawalFee)).toString();
      if (!await _confirmFunding(
        widget.english ? 'Confirm CCTP withdrawal' : '确认 CCTP 提款',
        widget.english
            ? '$normalized USDC will be sent to ${active.address} on Arbitrum Sepolia. Estimated receipt: $received USDC, before network gas and activation fees.'
            : '将向 Arbitrum Sepolia 地址 ${active.address} 提款 $normalized USDC。预计到账 $received USDC，尚需扣除网络 Gas 和激活费用。',
      )) {
        return;
      }
      final signer = await _fundingSigner(active);
      await _bridge.submitWithdrawal(
        wallet: signer,
        preview: quote,
        amount: normalized,
        ensureActiveWallet: () => _ensureActiveFundingWallet(active),
      );
      await _refresh();
      _notice(
        widget.english
            ? 'Withdrawal submitted. Arbitrum credit is still being verified.'
            : '提款请求已提交，正在核验 Arbitrum 到账。',
      );
    });
  }

  Future<WalletRecord> _activeFundingWallet() async {
    final active = await widget.walletVault.activeWallet();
    if (active == null) {
      throw StateError('Connect a wallet before using testnet funding.');
    }
    return active;
  }

  Future<WalletAdapter> _fundingSigner(WalletRecord active) async {
    final signer = active.kind == WalletKind.external
        ? widget.walletConnect.walletAdapter()
        : await widget.walletVault.unlockActive();
    if (signer == null) {
      throw StateError('Unlock the active wallet before signing.');
    }
    return signer;
  }

  /// 资金流程跨多个 await，发送关键步骤前确认活跃记录和地址仍是确认页上的账户。
  Future<void> _ensureActiveFundingWallet(WalletRecord expected) async {
    final active = await widget.walletVault.activeWallet();
    if (active == null ||
        active.id != expected.id ||
        active.address.toLowerCase() != expected.address.toLowerCase()) {
      throw StateError('The active wallet changed. Reopen the funding form.');
    }
  }

  Future<String?> _fundingAmountDialog({
    required String title,
    required String details,
    required String minimum,
  }) async {
    final amount = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(details, style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 14),
            TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: widget.english ? 'Amount' : '金额',
                suffixText: 'USDC',
                helperText: widget.english
                    ? 'Minimum $minimum · up to 6 decimals'
                    : '最低 $minimum · 最多 6 位小数',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.english ? 'Cancel' : '取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, amount.text.trim()),
            child: Text(widget.english ? 'Review' : '检查金额'),
          ),
        ],
      ),
    );
    amount.dispose();
    return value;
  }

  Future<bool> _confirmFunding(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.panel,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.english ? 'Cancel' : '取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(widget.english ? 'Continue to wallet' : '继续到钱包签名'),
            ),
          ],
        ),
      ) ??
      false;

  /// 状态检查只查询链上证据，消息区分到账、回滚和仍待确认。
  Future<void> _reconcileBridge(PendingFundingAction pending) async {
    await _run(() async {
      final updated = await _bridge.reconcile(pending);
      await _refresh();
      final message = switch (updated.status) {
        FundingActionStatus.credited =>
          widget.english ? 'Destination credit verified.' : '已核验目标账户到账。',
        FundingActionStatus.reverted =>
          widget.english
              ? 'The transaction reverted. Check chain balances before trying again.'
              : '交易已回滚；重试前请先核对链上余额。',
        _ =>
          widget.english
              ? 'Still pending. The app did not resend the request.'
              : '状态仍待确认，App 没有重发请求。',
      };
      _notice(message, error: updated.status == FundingActionStatus.reverted);
    });
  }

  /// 人工核对后才解除本地资金锁；解除并不等于已证明链上失败。
  Future<void> _resolveBridge(PendingFundingAction pending) async {
    final checked = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(widget.english ? 'Clear funding status?' : '清除待核验状态？'),
        content: Text(
          widget.english
              ? 'First verify the transaction on the relevant explorer and check both source and destination balances. This only clears the local retry lock; it does not resend a request.'
              : '请先在对应区块浏览器核对交易，并检查来源链与目标账户余额。此操作只清除本地重试锁，不会重发请求。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.english ? 'Keep pending' : '继续保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.english ? 'I verified it' : '已完成核对'),
          ),
        ],
      ),
    );
    if (checked != true) return;
    await _run(() async {
      await _bridge.resolveAfterManualCheck(pending);
      await _refresh();
    });
  }

  String _usdc(BigInt units) =>
      Decimal.parse(units.toString()).shift(-6).toString();

  /// 收集金额与方向，确认活跃钱包后调用内部划转服务。
  Future<void> _transferFunds() async {
    final wallet = await widget.walletVault.activeWallet();
    if (!mounted) return;
    if (wallet == null) {
      _notice(
        widget.english ? 'Connect a wallet first.' : '请先连接钱包。',
        error: true,
      );
      return;
    }
    final amount = TextEditingController();
    var toPerp = true;
    final details = await showDialog<({String amount, bool toPerp})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: AppColors.panel,
          title: Text(widget.english ? 'Transfer testnet USDC' : '划转测试网 USDC'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: true,
                    label: Text(widget.english ? 'Spot → Perp' : '现货 → 永续'),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text(widget.english ? 'Perp → Spot' : '永续 → 现货'),
                  ),
                ],
                selected: {toPerp},
                onSelectionChanged: (value) =>
                    setDialogState(() => toPerp = value.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: widget.english ? 'Amount' : '金额',
                  suffixText: 'USDC',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.english
                    ? 'The app refreshes available balances before asking the wallet to sign.'
                    : '请求钱包签名前会先重新读取可用余额。',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.english ? 'Cancel' : '取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                amount: amount.text.trim(),
                toPerp: toPerp,
              )),
              child: Text(widget.english ? 'Review and sign' : '检查并签名'),
            ),
          ],
        ),
      ),
    );
    amount.dispose();
    if (details == null) return;
    await _run(() async {
      final active = await widget.walletVault.activeWallet();
      if (active == null ||
          active.address.toLowerCase() != wallet.address.toLowerCase()) {
        throw StateError(
          'The active wallet changed. Reopen the transfer form.',
        );
      }
      final signer = active.kind == WalletKind.external
          ? widget.walletConnect.walletAdapter()
          : await widget.walletVault.unlockActive();
      if (signer == null) {
        throw StateError('Unlock the active wallet before signing.');
      }
      try {
        await _funding.submit(
          wallet: signer,
          amount: details.amount,
          toPerp: details.toPerp,
        );
        if (mounted) {
          _notice(
            widget.english
                ? 'Transfer confirmed by the exchange.'
                : '交易所已确认划转。',
          );
        }
      } on FundingTransferOutcomeUnknown {
        await _refresh();
        rethrow;
      }
      await _refresh();
    });
  }

  /// 用户确认已查看现货和永续余额后，移除未知划转记录。
  Future<void> _resolveTransfer(PendingFundingTransfer pending) async {
    final checked = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(widget.english ? 'Clear unknown transfer?' : '解除未知划转状态？'),
        content: Text(
          widget.english
              ? 'Only continue after checking both Spot and Perp balances for ${pending.amount} USDC. No request will be resent.'
              : '请先核对现货与永续余额，确认 ${pending.amount} USDC 划转结果。此操作不会重发请求。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.english ? 'Keep pending' : '继续保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.english ? 'I checked' : '已核对'),
          ),
        ],
      ),
    );
    if (checked != true) return;
    await _run(() async {
      await _funding.resolveAfterManualCheck(pending);
      await _refresh();
    });
  }

  /// 同一页面的操作串行执行，错误转成提示，finally 恢复按钮可用状态。
  Future<void> _run(Future<void> Function() action) =>
      AppDiagnostics.instance.trace('assets.action', () async {
        if (_working || !mounted) return;
        setState(() => _working = true);
        try {
          await action();
        } catch (error, stack) {
          AppDiagnostics.instance.error(
            'assets.action',
            error,
            stack,
            remote:
                error is! FundingTransferRejected &&
                error is! StateError &&
                error is! FormatException &&
                error is! ArgumentError,
          );
          if (error is FundingBridgeOutcomeUnknown) await _refresh();
          if (mounted) {
            _notice(
              error.toString().replaceFirst('Bad state: ', ''),
              error: true,
            );
          }
        } finally {
          if (mounted) setState(() => _working = false);
        }
      });

  void _notice(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? AppColors.negative : AppColors.surface,
      ),
    );
  }
}

class _ImportWalletDialog extends StatefulWidget {
  const _ImportWalletDialog({required this.english});
  final bool english;
  @override
  State<_ImportWalletDialog> createState() => _ImportWalletDialogState();
}

class _ImportWalletDialogState extends State<_ImportWalletDialog> {
  final _name = TextEditingController();
  final _secret = TextEditingController();
  bool _mnemonic = true;

  @override
  void dispose() {
    _name.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.english;
    return AlertDialog(
      backgroundColor: AppColors.panel,
      title: Text(en ? 'Import wallet' : '导入钱包'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(en ? 'Phrase' : '助记词')),
              ButtonSegment(
                value: false,
                label: Text(en ? 'Private key' : '私钥'),
              ),
            ],
            selected: {_mnemonic},
            onSelectionChanged: (selected) =>
                setState(() => _mnemonic = selected.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: InputDecoration(hintText: en ? 'Wallet name' : '钱包名称'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _secret,
            onChanged: (_) => setState(() {}),
            obscureText: true,
            maxLines: 1,
            decoration: InputDecoration(
              hintText: _mnemonic
                  ? (en ? '12 or 24 words' : '输入 12 或 24 个英文单词')
                  : (en ? '0x… private key' : '0x… 私钥'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(en ? 'Cancel' : '取消'),
        ),
        FilledButton(
          onPressed: _secret.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (
                  name: _name.text.trim(),
                  secret: _secret.text.trim(),
                  mnemonic: _mnemonic,
                )),
          child: Text(en ? 'Import' : '导入'),
        ),
      ],
    );
  }
}

class _WalletCard extends StatelessWidget {
  const _WalletCard({
    required this.wallet,
    required this.active,
    required this.english,
    required this.onSelect,
    required this.onRemove,
  });
  final WalletRecord wallet;
  final bool active;
  final bool english;
  final VoidCallback onSelect;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 7),
    decoration: BoxDecoration(
      color: AppColors.panel,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: active
            ? AppColors.accent.withValues(alpha: 0.4)
            : AppColors.border,
      ),
    ),
    child: ListTile(
      onTap: active ? null : onSelect,
      leading: CircleAvatar(
        backgroundColor: AppColors.surface,
        child: Icon(
          wallet.kind == WalletKind.local ? Icons.key_outlined : Icons.link,
          size: 17,
          color: AppColors.accent,
        ),
      ),
      title: Text(
        wallet.name,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${wallet.address.substring(0, 7)}…${wallet.address.substring(wallet.address.length - 5)}',
        style: const TextStyle(fontSize: 10, color: AppColors.muted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            const Icon(Icons.check_circle, color: AppColors.accent, size: 18)
          else
            TextButton(
              onPressed: onSelect,
              child: Text(
                english ? 'Switch' : '切换',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          IconButton(
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.delete_outline,
              size: 17,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});
  final String title;
  final String? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
      const Spacer(),
      if (trailing != null)
        Text(
          trailing!,
          style: const TextStyle(color: AppColors.muted, fontSize: 11),
        ),
    ],
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.outlined = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool outlined;
  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 17),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
    return SizedBox(
      height: 44,
      child: outlined
          ? OutlinedButton(onPressed: onPressed, child: child)
          : FilledButton.tonal(onPressed: onPressed, child: child),
    );
  }
}

class _PendingTransferCard extends StatelessWidget {
  const _PendingTransferCard({
    required this.pending,
    required this.english,
    required this.onVerified,
  });
  final PendingFundingTransfer pending;
  final bool english;
  final VoidCallback onVerified;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF392B1A),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF805C2D)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.warning_amber, size: 17, color: Color(0xFFF0B45B)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                english
                    ? 'Transfer result unknown · do not resend'
                    : '划转回报未知 · 请勿重发',
                style: const TextStyle(
                  color: Color(0xFFF0B45B),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '${pending.amount} USDC · ${pending.toPerp ? (english ? 'Spot → Perp' : '现货 → 永续') : (english ? 'Perp → Spot' : '永续 → 现货')}',
          style: const TextStyle(color: AppColors.muted, fontSize: 11),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: onVerified,
            child: Text(english ? 'I checked both balances' : '已核对两侧余额'),
          ),
        ),
      ],
    ),
  );
}

class _PendingBridgeCard extends StatelessWidget {
  const _PendingBridgeCard({
    required this.pending,
    required this.english,
    required this.onCheck,
    required this.onClear,
  });

  final PendingFundingAction pending;
  final bool english;
  final VoidCallback onCheck;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final title = pending.kind == FundingActionKind.deposit
        ? (english ? 'CCTP deposit' : 'CCTP 存款')
        : pending.kind == FundingActionKind.approve
        ? (english ? 'USDC approval' : 'USDC 授权')
        : (english ? 'CCTP withdrawal' : 'CCTP 提款');
    final status = switch (pending.status) {
      FundingActionStatus.unknown => english ? 'Unknown result' : '回报未知',
      FundingActionStatus.submitted => english ? 'Submitted' : '已提交',
      FundingActionStatus.confirmed => english ? 'Source confirmed' : '来源链已确认',
      FundingActionStatus.credited => english ? 'Credited' : '已到账',
      FundingActionStatus.reverted => english ? 'Reverted' : '已回滚',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF392B1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF805C2D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber,
                size: 17,
                color: Color(0xFFF0B45B),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '$title · $status',
                  style: const TextStyle(
                    color: Color(0xFFF0B45B),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '${pending.amount} USDC${pending.hash == null ? '' : ' · ${pending.hash!.substring(0, 10)}…${pending.hash!.substring(pending.hash!.length - 6)}'}',
            style: const TextStyle(color: AppColors.muted, fontSize: 11),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: onCheck,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(english ? 'Check status' : '核验状态'),
              ),
              TextButton(
                onPressed: onClear,
                child: Text(english ? 'Clear after verifying' : '核验后解除锁定'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

List<double> _history(List<List<dynamic>>? entries) => [
  for (final row in entries ?? <List<dynamic>>[])
    if (row.length == 2) double.tryParse(row.last.toString()),
].whereType<double>().where((v) => v.isFinite).toList();

/// 仅把账户历史数值绘成迷你趋势图，金额估值仍来自账户接口。
class _BalanceTrend extends CustomPainter {
  const _BalanceTrend(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    final low = values.reduce(math.min), high = values.reduce(math.max);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = high == low
          ? size.height / 2
          : (high - values[i]) / (high - low) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.accent
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_BalanceTrend old) => values != old.values;
}
