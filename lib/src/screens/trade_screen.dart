// 下单表单与行情之间的交互协调。收集输入、展示确认，再交给订单服务签名提交。

import '../diagnostics/app_diagnostics.dart';

import 'package:flutter/material.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:intl/intl.dart';

import '../app/theme.dart';
import '../market/coin_icon.dart';
import 'market_detail_screen.dart';
import 'market_screen.dart';
import 'orders_screen.dart';
import '../market/market.dart';
import '../market/market_data_service.dart';
import '../trading/order_safety.dart';
import '../trading/order_submission_service.dart';
import '../wallet/wallet_connect_service.dart';
import '../wallet/wallet_vault.dart';

enum _TicketKind {
  limit,
  market,
  stopMarket,
  stopLimit,
  takeProfitMarket,
  takeProfitLimit,
}

/// 主交易入口显示双向下单；sheetMarket 模式复用表单并限定弹层最初选择的方向。
class TradeScreen extends StatefulWidget {
  const TradeScreen({
    super.key,
    required this.marketData,
    required this.walletVault,
    required this.walletConnect,
    required this.openWallets,
    required this.english,
    this.active = true,
    this.sheetMarket,
    this.initialBuy = true,
  });

  final bool active, initialBuy;
  final MarketTicker? sheetMarket;
  final MarketDataService marketData;
  final WalletVault walletVault;
  final WalletConnectService walletConnect;
  final VoidCallback openWallets;
  final bool english;

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends State<TradeScreen> {
  final _scroll = ScrollController();
  final _price = TextEditingController();
  final _size = TextEditingController();
  final _trigger = TextEditingController();
  final _submission = OrderSubmissionService();
  MarketKind _marketKind = MarketKind.perpetual;
  _TicketKind _ticketKind = _TicketKind.limit;
  MarketTicker? _market;
  WalletRecord? _wallet;
  bool _reduceOnly = false;
  bool _advanced = false;
  bool _showChart = false;
  bool _working = false;
  int _slippageBps = 50;
  TimeInForce _tif = TimeInForce.gtc;
  String? _error;

  bool get _hasTrigger =>
      _ticketKind == _TicketKind.stopMarket ||
      _ticketKind == _TicketKind.stopLimit ||
      _ticketKind == _TicketKind.takeProfitMarket ||
      _ticketKind == _TicketKind.takeProfitLimit;
  bool get _isStop =>
      _ticketKind == _TicketKind.stopMarket ||
      _ticketKind == _TicketKind.stopLimit;
  bool get _hasTriggerLimit =>
      _ticketKind == _TicketKind.stopLimit ||
      _ticketKind == _TicketKind.takeProfitLimit;

  @override
  void initState() {
    super.initState();
    widget.walletVault.addListener(_loadWallet);
    _loadWallet();
    if (widget.sheetMarket case final requested?) {
      final selected =
          widget.marketData
              .marketsFor(requested.kind)
              .where((m) => m.coin == requested.coin)
              .firstOrNull ??
          requested;
      _market = selected;
      _marketKind = selected.kind;
      _price.text = selected.price?.toString() ?? '';
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.marketData.load(_marketKind).then(_selectInitial).ignore();
      }
    });
  }

  @override
  void dispose() {
    widget.walletVault.removeListener(_loadWallet);
    _scroll.dispose();
    _price.dispose();
    _size.dispose();
    _trigger.dispose();
    super.dispose();
  }

  Future<void> _loadWallet() async {
    final wallet = await widget.walletVault.activeWallet();
    if (mounted) setState(() => _wallet = wallet);
  }

  /// 依据 coin 查找当前选择，避免每次行情对象替换都把币种重置为默认 BTC。
  void _selectInitial(List<MarketTicker> markets) {
    if (!mounted || markets.isEmpty || markets.first.kind != _marketKind) {
      return;
    }
    final current = _market;
    final selected =
        current != null && markets.any((item) => item.coin == current.coin)
        ? markets.firstWhere((item) => item.coin == current.coin)
        : markets.firstWhere(
            (item) => item.coin == 'BTC',
            orElse: () => markets.first,
          );
    setState(() {
      _market = selected;
      if (!_supportedTicketKinds(selected.kind).contains(_ticketKind)) {
        _ticketKind = _TicketKind.limit;
      }
      _price.text = selected.price?.toString() ?? '';
      if (selected.kind != MarketKind.perpetual &&
          selected.kind != MarketKind.hip3) {
        _reduceOnly = false;
      }
    });
  }

  Future<void> _pickMarket() async {
    final selected = await showModalBottomSheet<MarketTicker>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: .82,
        child: MarketScreen(
          initialKind: _marketKind,
          marketData: widget.marketData,
          walletVault: widget.walletVault,
          walletConnect: widget.walletConnect,
          openWallets: widget.openWallets,
          english: widget.english,
          pick: (m) => Navigator.pop(ctx, m),
        ),
      ),
    );
    if (mounted &&
        selected != null &&
        (selected.kind != _marketKind || selected.coin != _market?.coin)) {
      _chooseMarket(selected);
    }
  }

  /// 切换市场时清除旧数量与触发价，并移除新市场不支持的订单设置。
  void _chooseMarket(MarketTicker market) {
    setState(() {
      _market = market;
      _marketKind = market.kind;
      if (!_supportedTicketKinds(market.kind).contains(_ticketKind)) {
        _ticketKind = _TicketKind.limit;
      }
      _size.clear();
      _price.text = market.price?.toString() ?? '';
      _trigger.clear();
      if (market.kind != MarketKind.perpetual &&
          market.kind != MarketKind.hip3) {
        _reduceOnly = false;
      }
      _error = null;
    });
  }

  /// 切换时收起键盘并把页面纵向位置归零，确保重新进入时图表就在可见区域。
  void _switchChart(bool show) {
    if (_showChart == show) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _showChart = show);
  }

  /// 校验行情时效和输入，展示摘要，确认后才解锁或请求外部钱包签名。
  Future<void> _reviewOrder(
    bool buy,
  ) => AppDiagnostics.instance.trace('order.review', () async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    final market =
        widget.marketData
            .marketsFor(_marketKind)
            .where((item) => item.coin == _market?.coin)
            .firstOrNull ??
        _market;
    try {
      if (market == null) return;
      if (!widget.marketData.hasFreshPrice(market.kind)) {
        throw ArgumentError('行情超过 30 秒未更新，请刷新后再提交。');
      }
      final price = switch (_ticketKind) {
        _TicketKind.market => marketSlippagePrice(
          market: market,
          isBuy: buy,
          slippageBps: _slippageBps,
        ),
        _TicketKind.stopMarket || _TicketKind.takeProfitMarket => _trigger.text,
        _ => _price.text,
      };
      final validated = validateOrderDraft(
        market: market,
        price: price,
        size: _size.text,
        reduceOnly: _reduceOnly,
      );
      if (_hasTrigger) {
        final trigger = double.tryParse(_trigger.text);
        final mark = market.price;
        if (trigger == null || mark == null) throw ArgumentError('触发价或标记价无效。');
        // 止损买单向上触发、卖单向下触发；止盈方向相反。
        final mustBeAbove = buy == _isStop;
        if (mustBeAbove ? trigger <= mark : trigger >= mark) {
          throw ArgumentError('触发价方向与当前标记价不符。');
        }
      }
      final reduceOnly = _reduceOnly;
      // 市价模式使用 IOC，在滑点限价范围内立即成交，未成交部分撤销。
      final tif = _ticketKind == _TicketKind.market ? TimeInForce.ioc : _tif;
      final triggerPrice = _hasTrigger ? _trigger.text : null;
      final triggerKind = _hasTrigger
          ? (_isStop ? TpslType.sl : TpslType.tp)
          : null;
      final triggerIsMarket = !_hasTriggerLimit;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.panel,
          title: Text(widget.english ? 'Review testnet order' : '确认测试网订单'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${market.displayName} · ${_sideLabel(buy, market.kind)}'),
              const SizedBox(height: 9),
              Text(
                '${widget.english ? 'Type' : '类型'}  ${_ticketLabel(_ticketKind, widget.english)}',
              ),
              Text(
                '${widget.english ? 'Size' : '数量'}  ${validated.size} ${market.base ?? market.coin}',
              ),
              Text(
                '${widget.english ? 'Price' : '限价'}  ${validated.price} ${market.quote}',
              ),
              if (_hasTrigger)
                Text('${widget.english ? 'Trigger' : '触发价'}  ${_trigger.text}'),
              Text(
                '${widget.english ? 'Value' : '名义金额'}  ${validated.notional.toString()} ${market.quote}',
              ),
              if (_reduceOnly) Text(widget.english ? 'Reduce only' : '只减仓'),
              const SizedBox(height: 10),
              Text(
                widget.english
                    ? 'The wallet will ask you to sign. This only targets testnet.'
                    : '随后由钱包请求签名；请求只会发送到测试网。',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(widget.english ? 'Back' : '返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(widget.english ? 'Sign and submit' : '签名并提交'),
            ),
          ],
        ),
      );
      // 取消确认会在获得签名适配器和发送订单之前返回。
      if (confirmed != true || !mounted) return;
      final wallet = _wallet;
      if (wallet == null) {
        throw StateError(
          widget.english ? 'Connect a wallet first.' : '请先连接钱包。',
        );
      }
      final signer = wallet.kind == WalletKind.external
          ? widget.walletConnect.walletAdapter()
          : await widget.walletVault.unlockActive();
      if (signer == null) {
        throw StateError(
          widget.english ? 'Unlock the active wallet first.' : '请先解锁当前钱包。',
        );
      }
      final result = await _submission.submit(
        wallet: signer,
        market: market,
        isBuy: buy,
        price: validated.price,
        size: validated.size,
        tif: tif,
        reduceOnly: reduceOnly,
        triggerPx: triggerPrice,
        triggerKind: triggerKind,
        triggerIsMarket: triggerIsMarket,
      );
      AppDiagnostics.instance.record(
        'order',
        'submit.result',
        data: {'state': result.state.name},
      );
      if (result.state == SubmissionState.unknown) {
        AppDiagnostics.instance.error(
          'order.unknown',
          const FormatException('Unknown response'),
          StackTrace.current,
        );
      }
      if (!mounted) return;
      final message = switch (result.state) {
        SubmissionState.resting =>
          widget.english
              ? 'Order resting. Check Orders & Positions.'
              : '订单已挂单，请到“订单与仓位”查看。',
        SubmissionState.filled => widget.english ? 'Order filled.' : '订单已成交。',
        SubmissionState.partial =>
          widget.english
              ? 'Partially filled. Review the order state.'
              : '订单部分成交，请核对委托状态。',
        SubmissionState.unknown =>
          widget.english
              ? 'Exchange response is unclear. Do not submit again; reconcile the client order ID.'
              : '交易所回报不明确。请勿重发，先核对客户端订单号。',
      };
      _notice(message, error: result.state == SubmissionState.unknown);
      if (result.state != SubmissionState.unknown) _size.clear();
    } catch (error, stack) {
      AppDiagnostics.instance.error(
        'order.review',
        error,
        stack,
        remote:
            error is! OrderRejected &&
            error is! StateError &&
            error is! FormatException &&
            error is! ArgumentError,
      );
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  });

  String _sideLabel(bool buy, MarketKind? kind) {
    final en = widget.english;
    final derivatives = kind == MarketKind.perpetual || kind == MarketKind.hip3;
    if (derivatives && !_reduceOnly) {
      return buy
          ? (en ? 'Buy / Long' : '买入（做多）')
          : (en ? 'Sell / Short' : '卖出（做空）');
    }
    return buy ? (en ? 'Buy' : '买入') : (en ? 'Sell' : '卖出');
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.marketData,
    builder: (context, _) {
      final english = widget.english;
      final markets = widget.marketData.marketsFor(_marketKind);
      final market =
          markets.where((item) => item.coin == _market?.coin).firstOrNull ??
          _market;
      final reduceSupported =
          market?.kind == MarketKind.perpetual ||
          market?.kind == MarketKind.hip3;
      final marketPrice = market?.price;
      String estimate(bool buy) => switch (_ticketKind) {
        _TicketKind.market =>
          marketPrice == null
              ? '—'
              : marketSlippagePrice(
                  market: market!,
                  isBuy: buy,
                  slippageBps: _slippageBps,
                ),
        _TicketKind.stopMarket || _TicketKind.takeProfitMarket =>
          _trigger.text.isEmpty ? '—' : _trigger.text,
        _ => _price.text.isEmpty ? '—' : _price.text,
      };
      final ticket = Padding(
        padding: const EdgeInsets.only(top: 4, right: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<_TicketKind>(
              key: ValueKey(_ticketKind),
              initialValue: _ticketKind,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: english ? 'Order type' : '订单类型',
              ),
              items: _supportedTicketKinds(market?.kind)
                  .map(
                    (kind) => DropdownMenuItem(
                      value: kind,
                      child: Text(
                        _ticketLabel(kind, english),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (kind) => setState(() {
                _ticketKind = kind ?? _TicketKind.limit;
                _error = null;
              }),
            ),
            if (_ticketKind == _TicketKind.limit || _hasTriggerLimit) ...[
              const SizedBox(height: 10),
              _NumberField(
                controller: _price,
                label: english ? 'Limit price' : '限价',
                suffix: market?.quote ?? 'USDC',
                onChanged: () => setState(() {}),
              ),
            ],
            if (_hasTrigger) ...[
              const SizedBox(height: 10),
              _NumberField(
                controller: _trigger,
                label: english ? 'Trigger price' : '触发价格',
                suffix: market?.quote ?? 'USDC',
                onChanged: () => setState(() {}),
              ),
            ],
            const SizedBox(height: 10),
            _NumberField(
              controller: _size,
              label: english ? 'Size' : '数量',
              suffix: market?.base ?? market?.coin ?? '',
              onChanged: () => setState(() {}),
            ),
            if (reduceSupported ||
                _ticketKind == _TicketKind.limit ||
                _ticketKind == _TicketKind.market)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                onPressed: () => setState(() => _advanced = !_advanced),
                icon: Icon(
                  _advanced ? Icons.expand_less : Icons.tune,
                  size: 16,
                ),
                label: Text(
                  _reduceOnly && !_advanced
                      ? (english ? 'Reduce only · settings' : '只减仓 · 设置')
                      : (english ? 'Order settings' : '委托设置'),
                ),
              ),
            if (_advanced) ...[
              if (_ticketKind == _TicketKind.market) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  initialValue: _slippageBps,
                  decoration: InputDecoration(
                    labelText: english ? 'Slippage bound' : '滑点保护',
                  ),
                  items: const [25, 50, 100, 200, 500]
                      .map(
                        (bps) => DropdownMenuItem(
                          value: bps,
                          child: Text('${(bps / 100).toStringAsFixed(2)}%'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _slippageBps = value ?? 50),
                ),
              ],
              if (_ticketKind == _TicketKind.limit) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<TimeInForce>(
                  initialValue: _tif,
                  decoration: InputDecoration(
                    labelText: english ? 'Time in force' : '有效方式',
                  ),
                  items: [TimeInForce.gtc, TimeInForce.ioc, TimeInForce.alo]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _tif = value ?? TimeInForce.gtc),
                ),
              ],
              if (reduceSupported) ...[
                const SizedBox(height: 4),
                Material(
                  color: Colors.transparent,
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _reduceOnly,
                    onChanged: (value) =>
                        setState(() => _reduceOnly = value ?? false),
                    title: Text(english ? 'Reduce only' : '只减仓'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
              ],
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: AppColors.negative,
                    fontSize: 11,
                  ),
                ),
              ),
            for (final buy
                in (widget.sheetMarket == null
                    ? [true, false]
                    : [widget.initialBuy])) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      english ? 'Est. price' : '预计委托价',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      estimate(buy),
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: buy
                        ? AppColors.positive
                        : AppColors.negative,
                    foregroundColor: AppColors.canvas,
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: _working || market == null
                      ? null
                      : _wallet == null
                      ? widget.openWallets
                      : () => _reviewOrder(buy),
                  child: Text(
                    _sideLabel(buy, market?.kind),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
            if (_wallet == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  english ? 'Connect wallet to trade' : '连接钱包后交易',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ),
          ],
        ),
      );
      if (widget.sheetMarket != null) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          children: [
            Row(
              children: [
                if (market != null) ...[
                  CoinIcon(market.iconSymbol),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    '${market?.displayName ?? ''} · ${english ? 'Testnet order' : '测试网委托'}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ticket,
          ],
        );
      }
      return ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 20),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickMarket,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (market != null) ...[
                                CoinIcon(market.iconSymbol),
                                const SizedBox(width: 8),
                              ],
                              Flexible(
                                child: Text(
                                  market?.displayName ??
                                      (english ? 'Select market' : '选择市场'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const Icon(Icons.expand_more, size: 20),
                            ],
                          ),
                          Text(
                            english
                                ? _marketKind.englishName
                                : _marketKind.chineseName,
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        english ? 'Market price' : '行情价格',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.muted,
                        ),
                      ),
                      Text(
                        marketPrice == null
                            ? '—'
                            : NumberFormat('#,##0.########')
                                  .format(marketPrice),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _showChart
                      ? (english ? 'Order ticket' : '返回下单')
                      : (english ? 'Chart' : 'K 线'),
                  onPressed: market == null
                      ? null
                      : () => _switchChart(!_showChart),
                  icon: Icon(
                    _showChart
                        ? Icons.receipt_long_outlined
                        : Icons.candlestick_chart_outlined,
                  ),
                ),
              ],
            ),
          ),
          if (market == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: ticket,
            )
          else if (widget.active)
            MarketQuotePanel(
              key: ValueKey((market.kind, market.coin)),
              market: market,
              marketData: widget.marketData,
              walletVault: widget.walletVault,
              english: english,
              ticket: ticket,
              showChart: _showChart,
              // 盘口选择只切回表单并填限价，用户仍需输入数量和确认方向。
              onPrice: (price) {
                _switchChart(false);
                setState(() {
                  _ticketKind = _TicketKind.limit;
                  _price.text = price;
                  _error = null;
                });
              },
            ),
          if (widget.active && !_showChart && market != null)
            OrdersScreen(
              embedded: true,
              walletVault: widget.walletVault,
              marketData: widget.marketData,
              walletConnect: widget.walletConnect,
              english: english,
              openWallets: widget.openWallets,
            ),
        ],
      );
    },
  );

  void _notice(String message, {bool error = false}) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? AppColors.negative : AppColors.surface,
        ),
      );
}

String _ticketLabel(_TicketKind kind, bool english) => switch (kind) {
  _TicketKind.limit => english ? 'Limit' : '限价单',
  _TicketKind.market => english ? 'Market with slippage cap' : '市价单（滑点保护）',
  _TicketKind.stopMarket => english ? 'Stop market' : '止损市价',
  _TicketKind.stopLimit => english ? 'Stop limit' : '止损限价',
  _TicketKind.takeProfitMarket => english ? 'Take profit market' : '止盈市价',
  _TicketKind.takeProfitLimit => english ? 'Take profit limit' : '止盈限价',
};

List<_TicketKind> _supportedTicketKinds(MarketKind? kind) =>
    kind == MarketKind.spot || kind == MarketKind.outcome
    ? const [_TicketKind.limit, _TicketKind.market]
    : _TicketKind.values;

/// 交易字段统一数字键盘与内部标签，实际数字规则由 order_safety 校验。
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.suffix,
    required this.onChanged,
  });
  final TextEditingController controller;
  final String label;
  final String suffix;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: (_) => onChanged(),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [],
    decoration: InputDecoration(
      labelText: label,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      hintText: '0',
      suffixText: suffix.isEmpty ? null : suffix,
    ),
  );
}
