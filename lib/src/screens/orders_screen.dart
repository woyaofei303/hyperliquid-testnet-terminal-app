// 账户、仓位、委托和成交展示。独立页面与交易页下方的嵌入区域共用查询和撤单逻辑。

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/diagnostic_http_client.dart';

import 'package:flutter/material.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:intl/intl.dart';

import '../app/theme.dart';
import '../market/coin_icon.dart';
import '../market/market.dart';
import '../market/market_data_service.dart';
import '../trading/order_submission_service.dart';
import '../wallet/wallet_connect_service.dart';
import '../wallet/wallet_vault.dart';

/// embedded 模式去掉独立页面外壳，用同一套逻辑展示交易页下方的订单区。
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({
    super.key,
    required this.walletVault,
    required this.marketData,
    required this.walletConnect,
    required this.english,
    required this.openWallets,
    this.embedded = false,
  });

  final WalletVault walletVault;
  final MarketDataService marketData;
  final WalletConnectService walletConnect;
  final bool english;
  final VoidCallback openWallets;
  final bool embedded;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final _pendingOrders = OrderSubmissionService();
  WalletRecord? _wallet;
  ClearinghouseState? _account;
  List<OpenOrder> _orders = const [];
  List<UserFill> _fills = const [];
  List<PendingOrder> _pending = const [];
  Object? _error;
  bool _loading = false;
  late String _selected = widget.embedded ? 'orders' : 'positions';

  @override
  void initState() {
    super.initState();
    widget.walletVault.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.walletVault.removeListener(_load);
    super.dispose();
  }

  /// 读取活跃账户的仓位、委托、成交与本地 pending；未连接钱包时清空账户数据。
  Future<void> _load() async {
    final wallet = await widget.walletVault.activeWallet();
    if (!mounted) return;
    setState(() {
      _wallet = wallet;
      _loading = wallet != null;
      _error = null;
    });
    if (wallet == null) {
      setState(() {
        _account = null;
        _orders = const [];
        _fills = const [];
        _pending = const [];
      });
      return;
    }
    final info = diagnosticInfo();
    try {
      final values = await Future.wait<Object>([
        info.clearinghouseState(wallet.address),
        info.frontendOpenOrders(wallet.address),
        info.userFills(wallet.address),
        _pendingOrders.pendingFor(wallet.address),
      ]);
      if (!mounted) return;
      setState(() {
        _account = values[0] as ClearinghouseState;
        _orders = values[1] as List<OpenOrder>;
        _fills = values[2] as List<UserFill>;
        _pending = values[3] as List<PendingOrder>;
        _loading = false;
      });
    } catch (error, stack) {
      AppDiagnostics.instance.error('orders.load', error, stack);
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    } finally {
      info.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = widget.english;
    final wallet = _wallet;
    final tabStrip = Row(
      children: [
        for (final entry in {
          'orders': wallet == null || _loading || _error != null
              ? (en ? 'Orders' : '委托')
              : "${en ? 'Orders' : '委托'} (${_orders.length})",
          'positions': en ? 'Positions' : '仓位',
          'fills': en ? 'Fills' : '成交',
        }.entries)
          Expanded(
            child: Semantics(
              selected: _selected == entry.key,
              child: InkWell(
                onTap: () => setState(() => _selected = entry.key),
                child: Container(
                  alignment: Alignment.center,
                  constraints: const BoxConstraints(minHeight: 44),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: _selected == entry.key
                            ? AppColors.accent
                            : AppColors.border,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      color: _selected == entry.key
                          ? AppColors.text
                          : AppColors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (widget.embedded && wallet != null)
          IconButton(
            onPressed: _load,
            tooltip: en ? 'Refresh account' : '刷新账户',
            icon: const Icon(Icons.refresh, size: 18),
          ),
      ],
    );
    final children = <Widget>[
      if (!widget.embedded)
        Row(
          children: [
            Text(
              en ? 'Orders & positions' : '订单与仓位',
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (wallet != null)
              IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 19),
              ),
          ],
        ),
      if (widget.embedded) tabStrip,
      if (wallet == null) ...[
        const SizedBox(height: 14),
        Padding(
          padding: EdgeInsets.symmetric(vertical: widget.embedded ? 6 : 44),
          child: _NoticeCard(
            icon: Icons.account_balance_wallet_outlined,
            action: en ? 'Manage wallets' : '前往钱包',
            onPressed: widget.openWallets,
            text: widget.embedded
                ? switch (_selected) {
                    'orders' =>
                      en
                          ? 'Connect a wallet to see open orders.'
                          : '连接钱包后可查看当前委托。',
                    'positions' =>
                      en ? 'Connect a wallet to see positions.' : '连接钱包后可查看持仓。',
                    _ =>
                      en ? 'Connect a wallet to see fills.' : '连接钱包后可查看成交记录。',
                  }
                : en
                ? 'Connect your testnet wallet to see positions, open orders and fills.'
                : '连接测试网钱包后，可在这里查看仓位、委托和成交记录。',
          ),
        ),
      ] else if (_loading) ...[
        const SizedBox(height: 36),
        const Center(child: CircularProgressIndicator(color: AppColors.accent)),
      ] else if (_error != null) ...[
        const SizedBox(height: 14),
        _NoticeCard(
          icon: Icons.error_outline,
          text: en ? 'Account data could not be loaded.' : '账户数据暂时无法读取。',
          action: en ? 'Retry' : '重试',
          onPressed: _load,
        ),
      ] else ...[
        const SizedBox(height: 10),
        if (!widget.embedded) _AccountSummary(account: _account, english: en),
        if (_pending.isNotEmpty) ...[
          const SizedBox(height: 12),
          _PendingOrdersCard(
            pending: _pending,
            english: en,
            onReconcile: _reconcile,
          ),
        ],
        const SizedBox(height: 14),
        if (!widget.embedded) tabStrip,
        const SizedBox(height: 10),
        if (_selected == 'positions')
          _PositionsList(account: _account, english: en)
        else if (_selected == 'orders')
          _OpenOrdersList(orders: _orders, english: en, onCancel: _cancelOrder)
        else
          _FillsList(fills: _fills, english: en),
      ],
    ];
    const padding = EdgeInsets.fromLTRB(16, 12, 16, 24);
    if (widget.embedded) {
      return Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        children: children,
      ),
    );
  }

  /// 核对使用原 cloid，结果只更新本地记录与列表，不创建第二笔订单。
  Future<void> _reconcile(PendingOrder pending) async {
    await _run(() async {
      final result = await _pendingOrders.reconcile(pending);
      await _load();
      final message = switch (result) {
        'found' =>
          widget.english
              ? 'Order found. Review the updated order list.'
              : '已查到订单，请检查最新委托记录。',
        'expired' =>
          widget.english
              ? 'No order found after the 30 second safety window.'
              : '超过 30 秒且查询无订单记录，已解除本地待确认状态。',
        _ =>
          widget.english
              ? 'Order is still pending; do not submit it again.'
              : '订单仍未确认，请勿重复提交。',
      };
      if (mounted) _notice(message);
    });
  }

  /// 先确认用户选择的 oid，再查市场 assetId，最后由当前钱包签名撤单。
  Future<void> _cancelOrder(OpenOrder order) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(widget.english ? 'Cancel order?' : '撤销委托？'),
        content: Text(
          '${order.coin} · ${order.side == 'B' ? 'BUY' : 'SELL'} ${order.sz} @ ${order.limitPx}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.english ? 'Keep' : '保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.english ? 'Confirm cancel' : '确认撤单'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    await _run(() async {
      final kind = order.coin.contains(':')
          ? MarketKind.hip3
          : order.coin.contains('/')
          ? MarketKind.spot
          : order.coin.startsWith('#')
          ? MarketKind.outcome
          : MarketKind.perpetual;
      if (widget.marketData.assetIdFor(order.coin) == null) {
        await widget.marketData.load(kind);
      }
      final asset = widget.marketData.assetIdFor(order.coin);
      if (asset == null) {
        throw StateError('Market metadata for this order is unavailable.');
      }
      final signer = await _signer();
      final exchange = ExchangeClient(
        wallet: signer,
        transport: diagnosticTransport(),
      );
      try {
        await exchange.cancelOrders(
          cancels: [CancelWire(asset: asset, oid: order.oid)],
        );
      } finally {
        exchange.close();
      }
      await _load();
      if (mounted) {
        _notice(
          widget.english
              ? 'Cancel request sent. Verify the order state.'
              : '撤单请求已发送，请检查最新委托状态。',
        );
      }
    });
  }

  Future<WalletAdapter> _signer() async {
    if (_wallet?.kind == WalletKind.external) {
      return widget.walletConnect.walletAdapter();
    }
    final signer = await widget.walletVault.unlockActive();
    if (signer == null) throw StateError('Unlock a wallet before signing.');
    return signer;
  }

  Future<void> _run(Future<void> Function() action) =>
      AppDiagnostics.instance.trace('orders.action', () async {
        try {
          await action();
        } catch (error, stack) {
          AppDiagnostics.instance.error(
            'orders.action',
            error,
            stack,
            remote:
                error is! StateError &&
                error is! FormatException &&
                error is! ArgumentError,
          );
          if (mounted) {
            _notice(
              error.toString().replaceFirst('Bad state: ', ''),
              error: true,
            );
          }
        }
      });

  void _notice(String text, {bool error = false}) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(text),
          backgroundColor: error ? AppColors.negative : AppColors.surface,
        ),
      );
}

class _AccountSummary extends StatelessWidget {
  const _AccountSummary({required this.account, required this.english});
  final ClearinghouseState? account;
  final bool english;

  @override
  Widget build(BuildContext context) {
    final equity = double.tryParse(account?.accountValue ?? '');
    final available = double.tryParse(account?.withdrawable ?? '');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Metric(
              label: english ? 'ACCOUNT VALUE' : '账户净值',
              value: equity == null
                  ? '—'
                  : NumberFormat.currency(
                      symbol: '\$',
                      decimalDigits: 2,
                    ).format(equity),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _Metric(
              label: english ? 'WITHDRAWABLE' : '可用余额',
              value: available == null
                  ? '—'
                  : NumberFormat.currency(
                      symbol: '\$',
                      decimalDigits: 2,
                    ).format(available),
            ),
          ),
        ],
      ),
    );
  }
}

/// 过滤数量为零的仓位；正负数量分别表示多头与空头。
class _PositionsList extends StatelessWidget {
  const _PositionsList({required this.account, required this.english});
  final ClearinghouseState? account;
  final bool english;

  @override
  Widget build(BuildContext context) {
    final positions = account?.assetPositions ?? const <Map<String, dynamic>>[];
    final active = positions
        .map((entry) => entry['position'])
        .whereType<Map<String, dynamic>>()
        .where(
          (position) =>
              (double.tryParse(position['szi']?.toString() ?? '') ?? 0) != 0,
        )
        .toList();
    if (active.isEmpty) {
      return _NoticeCard(
        icon: Icons.stacked_line_chart,
        text: english ? 'No open positions.' : '当前没有未平仓仓位。',
      );
    }
    return Column(
      children: [
        for (final position in active)
          _PositionCard(position: position, english: english),
      ],
    );
  }
}

class _PositionCard extends StatelessWidget {
  const _PositionCard({required this.position, required this.english});
  final Map<String, dynamic> position;
  final bool english;
  @override
  Widget build(BuildContext context) {
    final coin = position['coin']?.toString() ?? '—';
    final size = double.tryParse(position['szi']?.toString() ?? '') ?? 0;
    final pnl =
        double.tryParse(position['unrealizedPnl']?.toString() ?? '') ?? 0;
    final value =
        double.tryParse(position['positionValue']?.toString() ?? '') ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CoinIcon(coin, size: 22),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  coin,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SmallTag(
                text: size > 0
                    ? (english ? 'LONG' : '多')
                    : (english ? 'SHORT' : '空'),
                color: size > 0 ? AppColors.positive : AppColors.negative,
              ),
              const Spacer(),
              Text(
                '${english ? 'Size' : '数量'} ${size.abs()}',
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: english ? 'VALUE' : '仓位价值',
                  value: NumberFormat.currency(
                    symbol: '\$',
                    decimalDigits: 2,
                  ).format(value),
                ),
              ),
              Expanded(
                child: _Metric(
                  label: english ? 'UNREALIZED PNL' : '未实现盈亏',
                  value:
                      '${pnl >= 0 ? '+' : ''}${NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(pnl)}',
                  color: pnl >= 0 ? AppColors.positive : AppColors.negative,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: english ? 'ENTRY' : '开仓价',
                  value: position['entryPx']?.toString() ?? '—',
                ),
              ),
              Expanded(
                child: _Metric(
                  label: english ? 'LIQUIDATION' : '清算价',
                  value: position['liquidationPx']?.toString() ?? '—',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OpenOrdersList extends StatelessWidget {
  const _OpenOrdersList({
    required this.orders,
    required this.english,
    required this.onCancel,
  });
  final List<OpenOrder> orders;
  final bool english;
  final ValueChanged<OpenOrder> onCancel;

  @override
  Widget build(BuildContext context) {
    if (orders.isEmpty) {
      return _NoticeCard(
        icon: Icons.receipt_long_outlined,
        text: english ? 'No open orders.' : '当前没有未完成委托。',
      );
    }
    return Column(
      children: [
        for (final order in orders)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${order.coin} · ${order.side == 'B' ? 'BUY' : 'SELL'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${order.sz} @ ${order.limitPx} ${order.orderType == null ? '' : '· ${order.orderType}'}',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                      if (order.cloid != null)
                        Text(
                          'cloid ${order.cloid}',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 9,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => onCancel(order),
                  tooltip: english ? 'Cancel order' : '撤单',
                  icon: const Icon(
                    Icons.close,
                    color: AppColors.negative,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FillsList extends StatelessWidget {
  const _FillsList({required this.fills, required this.english});
  final List<UserFill> fills;
  final bool english;
  @override
  Widget build(BuildContext context) {
    if (fills.isEmpty) {
      return _NoticeCard(
        icon: Icons.history,
        text: english ? 'No recent fills.' : '暂无近期成交记录。',
      );
    }
    return Column(
      children: [
        for (final fill in fills.take(40))
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${fill.coin} · ${fill.dir}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        DateFormat('MM-dd HH:mm').format(
                          DateTime.fromMillisecondsSinceEpoch(fill.time)
                              .toLocal(),
                        ),
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      fill.px,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      fill.sz,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 明确展示结果待确认的订单，让用户先核对再继续提交。
class _PendingOrdersCard extends StatelessWidget {
  const _PendingOrdersCard({
    required this.pending,
    required this.english,
    required this.onReconcile,
  });
  final List<PendingOrder> pending;
  final bool english;
  final ValueChanged<PendingOrder> onReconcile;
  @override
  Widget build(BuildContext context) => Container(
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
            const Icon(Icons.warning_amber, color: Color(0xFFF0B45B), size: 18),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                english
                    ? 'Unconfirmed requests · do not resend'
                    : '有未确认请求 · 请勿重发',
                style: const TextStyle(
                  color: Color(0xFFF0B45B),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          english
              ? 'Look up the client order ID before taking another action.'
              : '先用客户端订单号查询状态，再进行其他操作。',
          style: const TextStyle(color: AppColors.muted, fontSize: 10),
        ),
        for (final order in pending)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${order.coin} · ${order.cloid}',
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
                TextButton(
                  onPressed: () => onReconcile(order),
                  child: Text(
                    english ? 'Reconcile' : '核对',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 9,
          letterSpacing: 0.5,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: TextStyle(
          color: color ?? AppColors.text,
          fontWeight: FontWeight.w600,
          fontSize: 12,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

class _SmallTag extends StatelessWidget {
  const _SmallTag({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700),
    ),
  );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.text,
    this.action,
    this.onPressed,
  });
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.panel,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Icon(icon, color: AppColors.muted, size: 21),
        const SizedBox(height: 9),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        if (action != null)
          TextButton(onPressed: onPressed, child: Text(action!)),
      ],
    ),
  );
}
