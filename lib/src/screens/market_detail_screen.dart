// 行情详情及交易页共用的报价面板。面板持有蜡烛、盘口、成交订阅和图表控制器。

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/diagnostic_http_client.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:intl/intl.dart';
import 'package:kline_flutter/kline_flutter.dart';

import '../app/theme.dart';
import '../market/coin_icon.dart';
import '../chart/chart_candle.dart';
import '../chart/chart_overlay.dart';
import '../chart/terminal_chart.dart';
import '../chart/chart_period_bar.dart';
import '../market/market.dart';
import '../market/book_view.dart';
import '../market/market_data_service.dart';
import '../wallet/wallet_vault.dart';
import '../wallet/wallet_connect_service.dart';
import 'trade_screen.dart';

/// 独立行情详情，底部买卖按钮以当前市场打开 TradeScreen 委托弹层。
class MarketDetailScreen extends StatelessWidget {
  const MarketDetailScreen({
    super.key,
    required this.market,
    required this.marketData,
    required this.walletVault,
    required this.walletConnect,
    required this.openWallets,
    required this.english,
  });

  final MarketTicker market;
  final MarketDataService marketData;
  final WalletVault walletVault;
  final WalletConnectService walletConnect;
  final VoidCallback openWallets;
  final bool english;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          CoinIcon(market.iconSymbol),
          const SizedBox(width: 8),
          Flexible(
            child: Text(market.displayName, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Row(
          children: [
            for (final buy in [true, false]) ...[
              if (!buy) const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    backgroundColor: buy
                        ? AppColors.positive
                        : AppColors.negative,
                  ),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (ctx) => Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.viewInsetsOf(ctx).bottom,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(ctx).height * .74,
                        ),
                        child: TradeScreen(
                          sheetMarket: market,
                          initialBuy: buy,
                          marketData: marketData,
                          walletVault: walletVault,
                          walletConnect: walletConnect,
                          openWallets: () {
                            Navigator.of(ctx)
                                .popUntil((route) => route.isFirst);
                            openWallets();
                          },
                          english: english,
                        ),
                      ),
                    ),
                  ),
                  child: Text(
                    buy ? (english ? 'Buy' : '买入') : (english ? 'Sell' : '卖出'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      children: [
        MarketQuotePanel(
          market: market,
          marketData: marketData,
          walletVault: walletVault,
          english: english,
        ),
      ],
    ),
  );
}

enum _QuoteTab { book, depth, trades, info }

/// 交易页与详情共用的数据持有者，showChart 只控制显示，图表打开后可保留挂载状态。
class MarketQuotePanel extends StatefulWidget {
  const MarketQuotePanel({
    super.key,
    required this.market,
    required this.marketData,
    required this.walletVault,
    required this.english,
    this.ticket,
    this.showChart = true,
    this.onPrice,
  });
  final MarketTicker market;
  final MarketDataService marketData;
  final WalletVault walletVault;
  final bool english;
  final Widget? ticket;
  final bool showChart;
  final ValueChanged<String>? onPrice;

  @override
  State<MarketQuotePanel> createState() => _MarketQuotePanelState();
}

class _MarketQuotePanelState extends State<MarketQuotePanel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  _QuoteTab _tab = _QuoteTab.book;
  late bool _chartVisited = widget.showChart;

  @override
  void didUpdateWidget(MarketQuotePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showChart) _chartVisited = true;
  }

  final _chartController = KLineController(
    initialIndicators: const ['ma', 'volume'],
    initialFollowLatest: false,
  );
  SubscriptionHandle? _candleSub;
  late final SubscriptionHandle _bookSub;
  late final SubscriptionHandle _tradeSub;

  /// 各类数据独立标记失败，盘口异常不必清空已加载的蜡烛。
  bool _bookFailed = false;
  bool _tradesFailed = false;
  int _walletSequence = 0;
  List<ChartCandle> _candles = [];
  L2Book? _book;
  List<Trade> _trades = [];
  List<ChartOverlayLine> _accountLines = const [];
  final List<double> _priceLines = [];
  String _period = '15m';
  bool _lineMode = false;
  late final StreamSubscription<WsConnectionState> _connection;
  Object? _chartError;
  final _reportedCandleIssues = <String>{};
  bool _loading = true;

  /// 每轮历史加载分配序号，旧周期或晚返回的请求无法覆盖较新的请求。
  int _loadSequence = 0;

  @override
  void initState() {
    super.initState();
    widget.walletVault.addListener(_loadAccountLines);
    _loadAccountLines();
    final ws = widget.marketData.realtime;
    _bookSub = ws.subscribeL2Book(widget.market.coin, (book) {
      AppDiagnostics.instance.count('ws.book');
      AppDiagnostics.instance.metrics['lastBookAt'] = DateTime.now()
          .toUtc()
          .toIso8601String();
      _acceptBook(book);
    });
    _tradeSub = ws.subscribeTrades(widget.market.coin, (trades) {
      AppDiagnostics.instance.count('ws.trades');
      _acceptTrades(trades);
    });
    _subscribeCandles();
    _connection = ws.stateChanges
        .where((state) => state == WsConnectionState.connected)
        .listen((_) {
          if (mounted) _loadCandles();
        });
    _refresh();
  }

  @override
  void dispose() {
    AppDiagnostics.instance.record(
      'ws',
      'unsubscribe.quote',
      data: {'coin': widget.market.coin, 'interval': _period},
    );
    _connection.cancel();
    _chartController.dispose();
    _candleSub?.cancel();
    _bookSub.cancel();
    _tradeSub.cancel();
    widget.walletVault.removeListener(_loadAccountLines);
    super.dispose();
  }

  /// 按 API 币种名和周期订阅，返回的取消句柄由当前面板释放。
  void _subscribeCandles() {
    AppDiagnostics.instance.record(
      'ws',
      'subscribe.candle',
      data: {'coin': widget.market.coin, 'interval': _period},
    );
    _candleSub = widget.marketData.realtime.subscribeCandle(
      widget.market.coin,
      _period,
      _applyCandle,
    );
  }

  void _refresh() {
    _loadCandles();
    _loadBook();
    _loadTrades();
  }

  /// 历史快照与已收到的推送合并，避免慢快照把最新蜡烛覆盖回旧值。
  Future<void> _loadCandles() =>
      AppDiagnostics.instance.trace('chart.snapshot', () async {
        final sequence = ++_loadSequence;
        setState(() {
          _chartError = null;
          _loading = true;
        });
        try {
          final candles = await widget.marketData.loadCandles(
            widget.market.coin,
            _period,
          );
          if (!mounted || sequence != _loadSequence) return;
          final accepted = candles.where(_validCandle).toList();
          AppDiagnostics.instance.record(
            'chart',
            'snapshot.accepted',
            data: {
              'coin': widget.market.coin,
              'interval': _period,
              'received': candles.length,
              'accepted': accepted.length,
            },
          );
          if (candles.isNotEmpty && accepted.isEmpty) {
            throw const FormatException('Invalid candle data');
          }
          _setBars(mergeCandles(_candles.map((c) => c.source), accepted));
        } catch (error, stack) {
          AppDiagnostics.instance.error('chart.snapshot', error, stack);
          if (mounted && sequence == _loadSequence) {
            setState(() => _chartError = error);
          }
        } finally {
          if (mounted && sequence == _loadSequence) {
            setState(() => _loading = false);
          }
        }
      });

  /// 只接收本币种且时间不早于已展示盘口的快照。
  void _acceptBook(L2Book book) {
    if (!mounted ||
        book.coin != widget.market.coin ||
        (book.time ?? 0) < (_book?.time ?? 0)) {
      return;
    }
    setState(() {
      _book = book;
      _bookFailed = false;
    });
  }

  Future<void> _loadBook() async {
    try {
      _acceptBook(await widget.marketData.loadOrderBook(widget.market.coin));
    } catch (error, stack) {
      AppDiagnostics.instance.error('book.snapshot', error, stack);
      if (mounted) setState(() => _bookFailed = _book == null);
    }
  }

  /// 按成交 tid 去重，再按时间倒序保留最近 50 笔。
  void _acceptTrades(List<Trade> trades) {
    if (!mounted) return;
    final merged = {
      for (final t in [..._trades, ...trades])
        if (t.coin == widget.market.coin) t.tid: t,
    };
    final sorted = merged.values.toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    setState(() {
      _trades = sorted.take(50).toList();
      _tradesFailed = false;
    });
  }

  Future<void> _loadTrades() async {
    try {
      _acceptTrades(
        await widget.marketData.loadRecentTrades(widget.market.coin),
      );
    } catch (error, stack) {
      AppDiagnostics.instance.error('trades.snapshot', error, stack);
      if (mounted) setState(() => _tradesFailed = _trades.isEmpty);
    }
  }

  /// 使用钱包请求序号屏蔽过期账户回包，只把当前币种的账户数据转换为价格线。
  Future<void> _loadAccountLines() async {
    final sequence = ++_walletSequence;
    final wallet = await widget.walletVault.activeWallet();
    if (!mounted || sequence != _walletSequence) return;
    if (wallet == null) {
      setState(() => _accountLines = const []);
      return;
    }
    final info = diagnosticInfo();
    try {
      final values = await Future.wait<Object>([
        info.clearinghouseState(wallet.address),
        info.frontendOpenOrders(wallet.address),
      ]);
      if (!mounted || sequence != _walletSequence) return;
      final account = values[0] as ClearinghouseState;
      setState(() {
        _accountLines = buildChartAccountLines(
          coin: widget.market.coin,
          positions: account.assetPositions,
          orders: values[1] as List<OpenOrder>,
          english: widget.english,
        );
      });
    } catch (error, stack) {
      AppDiagnostics.instance.error('chart.account', error, stack);
      if (mounted && sequence == _walletSequence) {
        setState(() => _accountLines = const []);
      }
    } finally {
      info.close();
    }
  }

  /// 合并后维护时间锚点，浏览历史时保持当前位置，位于末尾时跟进新蜡烛。
  void _setBars(List<Candle> bars) {
    final range = _chartController.visibleRange;
    final old = _candles;
    final extent =
        (chartCandleWidth + chartCandleSpacing) * _chartController.scale;
    final width = MediaQuery.sizeOf(context).width;
    final following =
        _chartController.selectedIndex == null &&
        (old.isEmpty ||
            range == null ||
            old.length * extent -
                    (_chartController.scrollOffset +
                        width * (1 - chartTailFraction)) <
                extent);
    final selected = _chartController.selectedIndex;
    final anchor = selected != null && selected < old.length
        ? old[selected].time
        : null;
    final watch = Stopwatch()..start();
    final next = developer.Timeline.timeSync(
      'chart.indicators',
      () => ChartCandle.fromCandles(bars),
    );
    AppDiagnostics.instance.metrics['indicatorMs'] =
        watch.elapsedMicroseconds / 1000;
    AppDiagnostics.instance.count('chart.recalculate');
    setState(() => _candles = next);
    if (bars.isEmpty) return;
    if (following &&
        (old.isEmpty ||
            bars.first.startTime != old.first.time ||
            bars.last.startTime != old.last.time ||
            range == null)) {
      _chartController.scrollToIndex(bars.length - 1, animated: false);
    } else if (old.isNotEmpty && old.first.time != bars.first.startTime) {
      final shift = bars.indexWhere((b) => b.startTime == old.first.time);
      final skipped = old.indexWhere((b) => b.time == bars.first.startTime);
      _chartController.setScrollOffset(
        math.max(
          0,
          _chartController.scrollOffset +
              (shift >= 0 ? shift : -math.max(0, skipped)) * extent,
        ),
      );
      if (anchor != null) {
        final next = bars.indexWhere((b) => b.startTime == anchor);
        _chartController.selectIndex(
          next < 0 ? null : next,
          localPosition: _chartController.selectionLocalPosition,
          contentPosition: _chartController.selectionContentPosition,
        );
      }
    }
  }

  /// 再次核对币种和周期，并用桶内累计成交笔数与成交量筛选推送。
  void _applyCandle(Candle candle) {
    AppDiagnostics.instance.count('ws.candle.received');
    AppDiagnostics.instance.metrics['lastCandleAt'] = DateTime.now()
        .toUtc()
        .toIso8601String();
    if (!mounted ||
        candle.symbol != widget.market.coin ||
        candle.interval != _period) {
      return;
    }
    if (!_validCandle(candle)) return;
    final last = _candles.lastOrNull;
    if (last != null && candle.startTime < _candles.first.time) return;
    final old = _candles.where((c) => c.time == candle.startTime).firstOrNull;
    if (old != null && !newerCandle(candle, old.source)) {
      AppDiagnostics.instance.count('ws.candle.unchanged');
      return;
    }
    AppDiagnostics.instance.count('ws.candle.accepted');
    _setBars(mergeCandles(_candles.map((c) => c.source), [candle]));
  }

  bool _validCandle(Candle candle) {
    final issue = candleIssue(candle);
    if (issue == null) return true;
    AppDiagnostics.instance.count('candle.invalid');
    if (_reportedCandleIssues.add(issue)) {
      AppDiagnostics.instance.error(
        'chart.invalid.$issue',
        const FormatException('Invalid candle'),
        StackTrace.current,
      );
    }
    AppDiagnostics.instance.record(
      'chart',
      'candle.rejected',
      level: 'warning',
      data: {'coin': widget.market.coin, 'interval': _period, 'reason': issue},
    );
    return false;
  }

  int _periodChange = 0;

  /// 先使旧请求失效并取消旧订阅，再绑定新周期；分时使用 1m 数据切换为折线。
  Future<void> _changePeriod(String period, {bool line = false}) async {
    if (line != _lineMode) setState(() => _lineMode = line);
    if (period == _period) return;
    final change = ++_periodChange;
    ++_loadSequence;
    _chartController.clearSelection();
    setState(() {
      _period = period;
      _candles = [];
      _loading = true;
    });
    final previous = _candleSub;
    _candleSub = null;
    await previous?.cancel();
    if (!mounted || change != _periodChange) return;
    _subscribeCandles();
    await _loadCandles();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final en = widget.english;
    final width = MediaQuery.sizeOf(context).width;
    final layout = chartLayout(width, rightInset: width * chartTailFraction);
    final secondaryHeight = secondaryChartIndicators
        .where((i) => _chartController.activeIndicatorIds.contains(i.id))
        .fold<double>(
          0,
          (h, i) => h + (i.height ?? layout.secondaryPaneHeight),
        );
    final isDetail = widget.ticket == null;
    final labels = {
      _QuoteTab.book: en ? 'Book' : '订单簿',
      _QuoteTab.depth: en ? 'Depth' : '深度',
      _QuoteTab.trades: en ? 'Trades' : '成交记录',
      _QuoteTab.info: en ? 'Info' : '币种资料',
    };
    final tabs = Row(
      children: [
        for (final tab in labels.entries)
          Expanded(
            child: Semantics(
              selected: tab.key == _tab,
              child: InkWell(
                onTap: () => setState(() => _tab = tab.key),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 46),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: 2,
                        color: _tab == tab.key
                            ? AppColors.accent
                            : AppColors.border,
                      ),
                    ),
                  ),
                  child: Text(
                    tab.value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _tab == tab.key
                          ? AppColors.accent
                          : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        IconButton(
          onPressed: _refresh,
          tooltip: en ? 'Refresh quotes' : '刷新行情',
          icon: const Icon(Icons.refresh, size: 18),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isDetail) ...[_quoteHeader(), const SizedBox(height: 8)],
        if (_chartVisited)
          // 图表与表单切换时保持图表内部滚动容器，避免控制器位置与新容器位置不一致。
          Offstage(
            offstage: !widget.showChart,
            child: ColoredBox(
              color: AppColors.canvas,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: ChartPeriodBar(
                            english: en,
                            selected: _lineMode ? 'line' : _period,
                            onSelect: (p) => _changePeriod(
                              p == 'line' ? '1m' : p,
                              line: p == 'line',
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _showIndicators(context),
                          tooltip: widget.english ? 'Indicators' : '技术指标',
                          icon: const Icon(
                            Icons.multiline_chart,
                            size: 17,
                            color: AppColors.muted,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          onPressed: () => _showDrawings(context),
                          tooltip: widget.english ? 'Drawing tools' : '绘图工具',
                          icon: const Icon(
                            Icons.edit_outlined,
                            size: 17,
                            color: AppColors.muted,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: layout.mainChartHeight + secondaryHeight,
                    child: _loading && _candles.isEmpty
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.accent,
                            ),
                          )
                        : _chartError != null && _candles.isEmpty
                        ? Center(
                            child: Text(
                              widget.english
                                  ? 'Chart data unavailable'
                                  : '图表数据暂不可用',
                              style: const TextStyle(color: AppColors.muted),
                            ),
                          )
                        : KLineWidget<ChartCandle>(
                            behavior: const KLineBehaviorConfig(
                              enableCrosshair: false,
                            ),
                            delegate: TerminalChartDelegate(
                              english: en,
                              interval: _period,
                              lineMode: _lineMode,
                              latest: _candles.lastOrNull,
                              priceLines: _priceLines,
                              accountLines: _accountLines,
                            ),
                            dataSource: _candles,
                            adapter: const ChartCandleAdapter(),
                            controller: _chartController,
                            initialIndicators: const ['ma', 'volume'],
                            mainIndicators: mainChartIndicators,
                            secondaryIndicators: secondaryChartIndicators,
                            theme: const KLineTheme(
                              backgroundColor: AppColors.canvas,
                              gridLineColor: AppColors.border,
                              crosshairColor: AppColors.accent,
                              textColor: AppColors.muted,
                              candleUpColor: AppColors.positive,
                              candleDownColor: AppColors.negative,
                              indicatorColors: [
                                Color(0xFFD28AF7),
                                Color(0xFF69BCEA),
                                Color(0xFF79CE86),
                                Color(0xFFF0B45B),
                              ],
                            ),
                            layout: layout,
                            emptyBuilder: (_) => Center(
                              child: Text(
                                widget.english ? 'No candles' : '暂无 K 线',
                                style: const TextStyle(color: AppColors.muted),
                              ),
                            ),
                          ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final entry in const {
                          'ma': 'MA',
                          'boll': 'BOLL',
                          'ema': 'EMA',
                          'volume': 'VOL',
                          'macd': 'MACD',
                          'kdj': 'KDJ',
                          'rsi': 'RSI',
                          'wr': 'WR',
                        }.entries)
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  _chartController.activeIndicatorIds.contains(
                                    entry.key,
                                  )
                                  ? AppColors.accent
                                  : AppColors.muted,
                              minimumSize: const Size(48, 44),
                            ),
                            onPressed: () => setState(
                              () => _chartController.toggleIndicator(entry.key),
                            ),
                            child: Text(entry.value),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (widget.showChart) ...[
          const Divider(height: 1),
          tabs,
          const SizedBox(height: 8),
          if (_tab == _QuoteTab.info)
            _MarketStatsCard(market: widget.market, english: en),
          if (_tab == _QuoteTab.book || _tab == _QuoteTab.depth)
            BookView(
              book: _book,
              depth: _tab == _QuoteTab.depth,
              english: en,
              market: widget.market,
              failed: _bookFailed,
              onPrice: widget.onPrice,
            ),
          if (_tab == _QuoteTab.trades)
            _RecentTradesCard(
              trades: _trades,
              english: en,
              failed: _tradesFailed,
            ),
        ] else if (widget.ticket != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: LayoutBuilder(
              builder: (context, box) {
                final compactBook = BookView(
                  book: _book,
                  depth: false,
                  compact: true,
                  onRetry: _loadBook,
                  english: en,
                  market: widget.market,
                  failed: _bookFailed,
                  onPrice: widget.onPrice,
                );
                if (box.maxWidth < 328 ||
                    MediaQuery.textScalerOf(context).scale(14) > 18) {
                  return Column(children: [widget.ticket!, compactBook]);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: widget.ticket!),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: compactBook),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  // 详情大字价优先取最后一根蜡烛收盘价，涨跌幅使用市场提供的前日价格。
  Widget _quoteHeader() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: ListenableBuilder(
      listenable: widget.marketData,
      builder: (context, _) {
        final market = widget.market;
        final english = widget.english;
        final ticker =
            widget.marketData
                .marketsFor(market.kind)
                .where((t) => t.coin == market.coin)
                .firstOrNull ??
            market;
        final close =
            _candles.lastOrNull?.close ??
            double.tryParse(_trades.firstOrNull?.px ?? '');
        final prior = ticker.previousPrice;
        final change = close == null || prior == null || prior <= 0
            ? null
            : (close / prior - 1) * 100;
        final color = change == null
            ? AppColors.text
            : change < 0
            ? AppColors.negative
            : AppColors.positive;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: english ? 'Last trade' : '最新成交价',
                    child: Text(
                      close == null
                          ? '—'
                          : NumberFormat('#,##0.########').format(close),
                      style: TextStyle(
                        fontSize: 32,
                        height: 1.15,
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '24h  ${change == null ? '—' : '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%'}',
                    style: TextStyle(color: color, fontSize: 13),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    english ? '24h turnover' : '24 小时成交额',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    '${ticker.dayVolume == null ? '—' : NumberFormat.compact(locale: 'en_US').format(ticker.dayVolume)} ${ticker.quote}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );

  /// 开关写入图表控制器，主副图定义来自 chart_candle.dart。
  void _showIndicators(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                  child: Text(
                    widget.english ? 'Chart indicators' : '图表指标',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final indicator in allChartIndicators)
                        ListTile(
                          dense: true,
                          title: Text(
                            indicator.label,
                            style: const TextStyle(fontSize: 13),
                          ),
                          trailing: Icon(
                            _chartController.activeIndicatorIds.contains(
                                  indicator.id,
                                )
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            color:
                                _chartController.activeIndicatorIds.contains(
                                  indicator.id,
                                )
                                ? AppColors.accent
                                : AppColors.muted,
                            size: 18,
                          ),
                          onTap: () {
                            setState(
                              () => _chartController.toggleIndicator(
                                indicator.id,
                              ),
                            );
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 目前只支持本面板内的水平价格线，离开面板后不跨页面持久化。
  void _showDrawings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.english ? 'Chart tools' : '图表工具',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              _ToolRow(
                icon: Icons.show_chart,
                label: widget.english ? 'Crosshair and zoom' : '十字线与缩放',
                enabled: true,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add, color: AppColors.accent),
                title: Text(
                  widget.english ? 'Add horizontal price line' : '添加水平价格线',
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await _editPriceLine();
                },
              ),
              for (var index = 0; index < _priceLines.length; index++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.horizontal_rule,
                    color: AppColors.accent,
                  ),
                  title: Text(
                    NumberFormat('#,##0.########').format(_priceLines[index]),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: widget.english ? 'Edit line' : '编辑',
                        onPressed: () async {
                          Navigator.pop(context);
                          await _editPriceLine(index);
                        },
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                      IconButton(
                        tooltip: widget.english ? 'Delete line' : '删除',
                        onPressed: () {
                          setState(() => _priceLines.removeAt(index));
                          Navigator.pop(context);
                        },
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: AppColors.negative,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入只接受有限正价格；添加和修改都操作同一份面板内价格线列表。
  Future<void> _editPriceLine([int? index]) async {
    final priceController = TextEditingController(
      text: index == null
          ? widget.market.price?.toString() ?? ''
          : _priceLines[index].toString(),
    );
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(
          index == null
              ? (widget.english ? 'Add price line' : '添加价格线')
              : (widget.english ? 'Edit price line' : '编辑价格线'),
        ),
        content: TextField(
          controller: priceController,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: widget.english ? 'Price' : '价格',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.english ? 'Cancel' : '取消'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(priceController.text.trim());
              if (parsed == null || !parsed.isFinite || parsed <= 0) return;
              Navigator.pop(context, parsed);
            },
            child: Text(widget.english ? 'Save' : '保存'),
          ),
        ],
      ),
    );
    priceController.dispose();
    if (value == null || !mounted) return;
    setState(() {
      if (index == null) {
        _priceLines.add(value);
      } else {
        _priceLines[index] = value;
      }
    });
  }
}

class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.price,
    required this.size,
    required this.color,
  });
  final String price;
  final String size;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            NumberFormat('#,##0.########').format(double.tryParse(price) ?? 0),
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Text(
          NumberFormat('#,##0.####').format(double.tryParse(size) ?? 0),
          style: const TextStyle(color: AppColors.text, fontSize: 10),
        ),
      ],
    ),
  );
}

class _RecentTradesCard extends StatelessWidget {
  const _RecentTradesCard({
    required this.trades,
    required this.english,
    required this.failed,
  });
  final List<Trade> trades;
  final bool english;
  final bool failed;
  @override
  Widget build(BuildContext context) => _PanelCard(
    title: english ? 'Recent trades' : '最新成交',
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(english ? 'PRICE' : '价格', style: _tiny)),
            Text(english ? 'SIZE' : '数量', style: _tiny),
          ],
        ),
        const SizedBox(height: 5),
        for (final trade in trades.take(10))
          _BookRow(
            price: trade.px,
            size: trade.sz,
            color: trade.side == 'B' ? AppColors.positive : AppColors.negative,
          ),
        if (trades.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              failed
                  ? (english ? 'Trades unavailable' : '成交数据暂不可用')
                  : (english ? 'Waiting for trades' : '等待成交'),
              style: const TextStyle(color: AppColors.muted, fontSize: 10),
            ),
          ),
      ],
    ),
  );
}

class _MarketStatsCard extends StatelessWidget {
  const _MarketStatsCard({required this.market, required this.english});
  final MarketTicker market;
  final bool english;
  @override
  Widget build(BuildContext context) => _PanelCard(
    title: english ? 'Market info' : '市场信息',
    child: Row(
      children: [
        Expanded(
          child: _Stat(
            label: english ? '24h volume' : '24 小时成交额',
            value: market.dayVolume == null
                ? '—'
                : NumberFormat.compactCurrency(symbol: '')
                      .format(market.dayVolume),
          ),
        ),
        Expanded(
          child: _Stat(
            label: english ? 'Market' : '市场类型',
            value: english ? market.kind.englishName : market.kind.chineseName,
          ),
        ),
        Expanded(
          child: _Stat(
            label: english ? 'Size decimals' : '数量精度',
            value: '${market.sizeDecimals}',
          ),
        ),
      ],
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: _tiny),
      const SizedBox(height: 6),
      Text(
        value,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.panel,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.icon,
    required this.label,
    required this.enabled,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      icon,
      color: enabled ? AppColors.accent : AppColors.muted,
      size: 19,
    ),
    title: Text(
      label,
      style: TextStyle(
        color: enabled ? AppColors.text : AppColors.muted,
        fontSize: 13,
      ),
    ),
    trailing: enabled
        ? const Icon(Icons.check, color: AppColors.accent, size: 17)
        : null,
  );
}

const _tiny = TextStyle(
  color: AppColors.muted,
  fontSize: 9,
  letterSpacing: 0.5,
);
