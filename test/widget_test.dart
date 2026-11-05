// 用替身行情和钱包运行组件测试，检查导航、图表更新与手势、双语表单和确认方向；不访问真实账户或发送交易。

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hyperliquid_testnet_terminal/src/app/theme.dart';

import 'package:flutter/material.dart';
import 'package:hyperliquid_testnet_terminal/src/screens/trade_screen.dart';
import 'package:hyperliquid_testnet_terminal/src/wallet/wallet_connect_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kline_flutter/kline_flutter.dart';
import 'package:hyperliquid_testnet_terminal/src/chart/chart_candle.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';
import 'package:hyperliquid_testnet_terminal/src/app/terminal_app.dart';
import 'package:hyperliquid_testnet_terminal/src/market/market.dart';
import 'package:hyperliquid_testnet_terminal/src/market/market_data_service.dart';
import 'package:hyperliquid_testnet_terminal/src/wallet/wallet_vault.dart';

// 固定行情替代外部 HTTP，避免网络波动让组件断言不稳定。
class _MarketData extends MarketDataService {
  _MarketData({this._markets = const [], super.websocket});

  List<MarketTicker> _markets;

  @override
  bool get connected => false;

  @override
  bool isLoading(MarketKind kind) => false;

  @override
  Object? errorFor(MarketKind kind) => null;

  @override
  List<MarketTicker> marketsFor(MarketKind kind) => _markets;

  @override
  bool hasFreshPrice(MarketKind kind) => false;

  @override
  Future<List<MarketTicker>> load(
    MarketKind kind, {
    bool refresh = false,
  }) async {
    notifyListeners();
    return _markets;
  }

  @override
  Future<List<Candle>> loadCandles(String coin, String interval) async => [
    for (var i = 0; i < 150; i++)
      Candle(
        startTime: i * 60000,
        endTime: (i + 1) * 60000 - 1,
        open: 96,
        close: 99,
        high: 100,
        low: 95,
        volume: 1,
        numTrades: 1,
      ),
  ];

  @override
  Future<L2Book> loadOrderBook(String coin) async => L2Book(
    coin: coin,
    bids: const [
      L2Level(price: '99.5', size: '2'),
      L2Level(price: '98', size: '3'),
    ],
    asks: const [L2Level(price: '100.5', size: '4')],
  );

  @override
  Future<List<Trade>> loadRecentTrades(String coin) async =>
      throw StateError('unavailable');

  void updatePrice(String coin, double price) {
    _markets = [
      for (final market in _markets)
        market.coin == coin ? market.withPrice(price) : market,
    ];
    notifyListeners();
  }
}

// 保留订阅回调供测试主动推送蜡烛，模拟实时更新而不打开网络连接。
class _CandleSocket extends WebSocketClient {
  late void Function(Candle) emit;
  @override
  SubscriptionHandle subscribeCandle(
    String coin,
    String interval,
    void Function(Candle) handler,
  ) {
    emit = handler;
    return super.subscribeCandle(coin, interval, handler);
  }
}

// 延迟返回历史快照，用于检查快照晚到时不会覆盖较新的推送。
class _PendingHistory extends _MarketData {
  _PendingHistory(_CandleSocket ws)
    : super(
        websocket: ws,
        markets: _btcMarketData().marketsFor(MarketKind.perpetual),
      );
  final snapshot = Completer<List<Candle>>();
  @override
  Future<List<Candle>> loadCandles(String coin, String interval) =>
      snapshot.future;
}

// 未连接钱包的替身，绕过设备安全存储插件。
class _WalletVault extends WalletVault {
  @override
  Future<List<WalletRecord>> listWallets() async => const [];

  @override
  Future<WalletRecord?> activeWallet() async => null;
}

// 只提供确认页需要的账户元数据，不提供实际签名能力。
class _ReviewVault extends _WalletVault {
  @override
  Future<WalletRecord?> activeWallet() async => const WalletRecord(
    id: 'test',
    name: 'Demo',
    address: '0x0000000000000000000000000000000000000001',
    kind: WalletKind.local,
  );
}

// 提供有效价格时效，让测试到达表单确认步骤。
class _FreshMarket extends _MarketData {
  _FreshMarket()
    : super(markets: _btcMarketData().marketsFor(MarketKind.perpetual));
  @override
  bool hasFreshPrice(MarketKind kind) => true;
}

_MarketData _btcMarketData() => _MarketData(
  markets: const [
    MarketTicker(
      coin: 'BTC',
      kind: MarketKind.perpetual,
      price: 100,
      previousPrice: 99,
      dayVolume: 1000000,
      sizeDecimals: 5,
      assetId: 0,
      base: 'BTC',
    ),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('the four-tab shell opens read-only without a wallet', (
    tester,
  ) async {
    await tester.pumpWidget(
      TerminalApp(marketData: _MarketData(), walletVault: _WalletVault()),
    );
    await tester.pumpAndSettle();

    expect(find.text('HYPERLIQUID'), findsOneWidget);
    expect(find.text('市场行情'), findsOneWidget);
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    expect(find.text('资产与账户'), findsOneWidget);

    await tester.tap(find.text('交易'));
    await tester.pumpAndSettle();
    expect(find.text('交易'), findsWidgets);
    expect(find.text('连接钱包后交易'), findsOneWidget);
  });

  testWidgets('trade market selection survives realtime ticker replacement', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final marketData = _btcMarketData();
    await tester.pumpWidget(
      TerminalApp(marketData: marketData, walletVault: _WalletVault()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('交易').last);
    await tester.pumpAndSettle();

    marketData.updatePrice('BTC', 101);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('101'), findsOneWidget);
    expect(find.byTooltip('K 线'), findsOneWidget);
    expect(find.text('有效方式'), findsNothing);
    await tester.tap(find.text('委托设置'));
    await tester.pumpAndSettle();
    expect(find.text('有效方式'), findsOneWidget);
    await tester.tap(find.byTooltip('K 线'));
    await tester.pumpAndSettle();
    final candles = find.byType(KLineWidget<ChartCandle>);
    final chartState = tester.state(candles);
    expect(
      tester.getBottomLeft(candles).dy,
      lessThan(tester.getTopLeft(find.text('订单簿')).dy),
    );
    await tester.ensureVisible(find.text('深度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深度'));
    await tester.pumpAndSettle();
    expect(find.textContaining('累计挂单量'), findsOneWidget);
    await tester.tap(find.text('订单簿'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('99.5').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('99.5').first);
    await tester.pumpAndSettle();
    expect(candles, findsNothing);
    expect(
      tester.getTopLeft(find.text('委托')).dy,
      greaterThan(tester.getBottomLeft(find.text('卖出（做空）')).dy),
    );
    await tester.tap(find.byTooltip('K 线'));
    await tester.pump();
    expect(tester.state(candles), same(chartState));
    expect(
      tester.getRect(candles).top,
      lessThan(tester.view.physicalSize.height / tester.view.devicePixelRatio),
    );
    await tester.tap(find.byTooltip('返回下单'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .any((f) => f.controller?.text == '99.5'),
      isTrue,
    );
    await tester.tap(find.text('市场').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('BTC').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('技术指标'), findsOneWidget);
    final chart = tester.widget<KLineWidget<ChartCandle>>(
      find.byType(KLineWidget<ChartCandle>),
    );
    expect(chart.controller!.visibleRange?.end, 149);
    marketData.updatePrice('BTC', 104);
    await tester.pump();
    await tester.tap(find.text('卖出'));
    await tester.pumpAndSettle();
    expect(find.text('BTC · 测试网委托'), findsOneWidget);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .any((f) => f.controller?.text == '104.0'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ticket labels stay inside filled controls in both languages', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      TerminalApp(marketData: _btcMarketData(), walletVault: _WalletVault()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('交易'));
    await tester.pumpAndSettle();
    for (final en in [false, true]) {
      if (en) {
        await tester.tap(find.byTooltip('Switch to English'));
        await tester.pumpAndSettle();
      }
      for (final label
          in en
              ? ['Order type', 'Limit price', 'Size']
              : ['订单类型', '限价', '数量']) {
        final field = find.byWidgetPredicate(
          (w) => w is InputDecorator && w.decoration.labelText == label,
        );
        final caption = find.descendant(of: field, matching: find.text(label));
        final bounds = tester.getRect(field);
        final text = tester.getRect(caption);
        expect(text.top, greaterThan(bounds.top + 1));
        expect(text.bottom, lessThan(bounds.bottom));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('market detail switches data below the same chart', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      TerminalApp(marketData: _btcMarketData(), walletVault: _WalletVault()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('BTC').first);
    await tester.pumpAndSettle();

    final candles = find.byType(KLineWidget<ChartCandle>);
    final chartState = tester.state(candles);
    final book = find.text('订单簿');
    expect(
      tester.getBottomLeft(candles).dy,
      lessThan(tester.getTopLeft(book).dy),
    );
    expect(find.text('99.5'), findsOneWidget);
    final buyPosition = tester.getCenter(find.text('买入'));
    for (final entry in {
      '深度': '累计挂单量',
      '成交记录': '最新成交',
      '币种资料': '24 小时成交额',
      '订单簿': '99.5',
    }.entries) {
      final tab = find.text(entry.key);
      await tester.ensureVisible(tab);
      await tester.pumpAndSettle();
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(find.textContaining(entry.value), findsWidgets);
      expect(tester.state(candles), same(chartState));
      expect(tester.getCenter(find.text('买入')), buyPosition);
    }
  });

  testWidgets(
    'late history, duplicate push and rollover keep the right candle and headline',
    (tester) async {
      final socket = _CandleSocket(), data = _PendingHistory(socket);
      await tester.pumpWidget(
        TerminalApp(marketData: data, walletVault: _WalletVault()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('BTC').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      Candle bar(int start, int n, double close, {String interval = '15m'}) =>
          Candle(
            startTime: start,
            endTime: start + 899999,
            open: 95,
            high: 110,
            low: 92,
            close: close,
            volume: n * .01,
            numTrades: n,
            symbol: 'BTC',
            interval: interval,
          );
      final update = bar(900000, 8, 102);
      socket.emit(update);
      await tester.pump();
      data.snapshot.complete([bar(0, 2, 94), bar(900000, 3, 97)]);
      await tester.pumpAndSettle();
      List<ChartCandle> bars() => tester
          .widget<KLineWidget<ChartCandle>>(
            find.byType(KLineWidget<ChartCandle>),
          )
          .dataSource;
      expect(bars().map((b) => b.close), [94, 102]);
      expect(find.text('102'), findsOneWidget);
      socket.emit(bar(900000, 5, 98));
      socket.emit(bar(1800000, 40, 106, interval: '1m'));
      final next = bar(1800000, 1, 104);
      socket.emit(next);
      socket.emit(next);
      await tester.pumpAndSettle();
      expect(bars().map((b) => b.close), [94, 102, 104]);
      expect(find.text('104'), findsOneWidget);
    },
  );

  testWidgets(
    'historical candles and volume fill the live-edge gap after a pan',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final screen = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: screen,
          child: TerminalApp(
            marketData: _btcMarketData(),
            walletVault: _WalletVault(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('BTC').first);
      await tester.pumpAndSettle();
      final chart = find.byType(KLineWidget<ChartCandle>);
      final rect = tester.getRect(chart),
          layout = tester.widget<KLineWidget<ChartCandle>>(chart).layout;
      Future<List<bool>> rightStrip() async {
        final boundary =
            screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            bool hasBars(double top, double bottom) {
              for (
                var y = (rect.top + top).ceil();
                y < (rect.top + bottom).floor();
                y++
              ) {
                for (
                  var x = (rect.left + rect.width * .79).ceil();
                  x < (rect.left + rect.width * .85).floor();
                  x++
                ) {
                  final px = data.getUint32((y * image.width + x) * 4);
                  if ((px >> 8) == (AppColors.positive.toARGB32() & 0xffffff)) {
                    return true;
                  }
                }
              }
              return false;
            }

            return [
              hasBars(
                layout.mainChartHeight * .25,
                layout.mainChartHeight * .75,
              ),
              hasBars(layout.mainChartHeight + 20, rect.height - 20),
            ];
          } finally {
            image.dispose();
          }
        }))!;
      }

      expect(await rightStrip(), [false, false]);
      final point = rect.topLeft + const Offset(70, 115);
      await tester.dragFrom(point, const Offset(170, 0));
      await tester.pumpAndSettle();
      expect(
        await rightStrip(),
        [true, true],
        reason: 'Both panes should draw bars between the old boundary and the price scale',
      );
      final reset = find.byTooltip('回到最新');
      expect(reset, findsOneWidget);
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(await rightStrip(), [false, false]);
    },
  );

  testWidgets(
    'live price follows socket updates across a historical viewport',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final socket = _CandleSocket();
      final data = _PendingHistory(socket);
      await tester.pumpWidget(
        TerminalApp(marketData: data, walletVault: _WalletVault()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('BTC').first);
      await tester.pump();
      final bars = await _btcMarketData().loadCandles('BTC', '15m');
      data.snapshot.complete(bars);
      await tester.pumpAndSettle();
      final chart = find.byType(KLineWidget<ChartCandle>);
      Offset firstDash() {
        final fixed = find
            .descendant(of: chart, matching: find.byType(CustomPaint))
            .first;
        final canvas = TestRecordingCanvas();
        tester
            .widget<CustomPaint>(fixed)
            .painter!
            .paint(canvas, tester.getSize(fixed));
        final lines = canvas.invocations
            .map((r) => r.invocation)
            .where((i) => i.memberName == #drawLine);
        final dash = lines.firstWhere((i) {
          final a = i.positionalArguments;
          return a[0] is Offset &&
              (a[1] as Offset) - (a[0] as Offset) == const Offset(3, 0);
        });
        return dash.positionalArguments.first as Offset;
      }

      expect(firstDash().dx, greaterThan(200));
      await tester.dragFrom(
        tester.getTopLeft(chart) + const Offset(70, 110),
        const Offset(230, 0),
      );
      await tester.pumpAndSettle();
      final historical = firstDash();
      expect(historical.dx, 0);
      // The new live close is outside every historical candle on screen.
      socket.emit(
        Candle(
          startTime: bars.last.startTime,
          endTime: bars.last.endTime,
          open: 96,
          high: 150,
          low: 95,
          close: 150,
          volume: 2,
          numTrades: 2,
          symbol: 'BTC',
          interval: '15m',
        ),
      );
      await tester.pumpAndSettle();
      final updated = firstDash();
      expect(updated.dx, 0);
      expect(updated.dy, inInclusiveRange(25, historical.dy - 1));
      final reset = find.byTooltip('回到最新');
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(firstDash().dx, greaterThan(200));
    },
  );

  testWidgets(
    'More opens an interval sheet, selects 4h and saves quick intervals',
    (tester) async {
      await tester.pumpWidget(
        TerminalApp(marketData: _btcMarketData(), walletVault: _WalletVault()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('BTC').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多周期'));
      await tester.pumpAndSettle();
      expect(find.text('更多时间周期'), findsOneWidget);
      final sheet = find.byType(BottomSheet);
      Finder option(String label) =>
          find.descendant(of: sheet, matching: find.text(label));
      await tester.tap(option('4时'));
      await tester.pump();
      // Let the SDK finish cancelling the previous channel outside the fake clock.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      await tester.tap(find.byTooltip('更多周期'));
      await tester.pumpAndSettle();
      await tester.tap(option('选择时间周期偏好'));
      await tester.pumpAndSettle();
      await tester.tap(option('1分'));
      await tester.pumpAndSettle();
      await tester.tap(option('4时'));
      await tester.pumpAndSettle();
      await tester.tap(option('保存'));
      await tester.pumpAndSettle();
      expect(find.text('4时'), findsOneWidget);
      expect(find.text('1分'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('BTC').first);
      await tester.pumpAndSettle();
      expect(find.text('4时'), findsOneWidget);
      expect(find.text('1分'), findsNothing);
    },
  );
  for (final english in [false, true]) {
    testWidgets(
      'tap, inspect, dismiss, long press and pan (english=$english)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          TerminalApp(
            marketData: _btcMarketData(),
            walletVault: _WalletVault(),
          ),
        );
        await tester.pumpAndSettle();
        if (english) {
          await tester.tap(find.byTooltip('Switch to English'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('BTC').first);
        await tester.pumpAndSettle();
        final chart = find.byType(KLineWidget<ChartCandle>);
        final widget = tester.widget<KLineWidget<ChartCandle>>(chart);
        final rect = tester.getRect(chart);
        expect(rect.left, 0);
        expect(rect.width, 390);
        expect(widget.layout.chartPadding.right, closeTo(390 * .25, .01));
        expect(
          widget.layout.secondaryPaneHeight / widget.layout.mainChartHeight,
          closeTo(.30, .02),
        );
        expect(find.text(english ? '15m' : '15分'), findsOneWidget);
        final center = rect.topLeft + const Offset(115, 110);
        await tester.tapAt(center);
        await tester.pumpAndSettle();
        final readout = find.text(english ? 'Open  96' : '开盘  96');
        expect(readout, findsOneWidget);
        final selected = widget.controller!.selectedIndex;
        expect(selected, isNotNull);
        await tester.tapAt(center + const Offset(35, 0));
        await tester.pumpAndSettle();
        expect(widget.controller!.selectedIndex, isNull);
        expect(readout, findsNothing);
        await tester.longPressAt(center);
        await tester.pumpAndSettle();
        expect(readout, findsOneWidget);
        final before = widget.controller!.scrollOffset;
        await tester.dragFrom(center, const Offset(105, 0));
        await tester.pumpAndSettle();
        expect(widget.controller!.selectedIndex, isNot(selected));
        expect(readout, findsOneWidget);
        expect(widget.controller!.scrollOffset, before);
        await tester.tapAt(center);
        await tester.pumpAndSettle();
        await tester.dragFrom(center, const Offset(105, 0));
        await tester.pumpAndSettle();
        expect(widget.controller!.scrollOffset, lessThan(before));
        expect(widget.controller!.selectedIndex, isNull);
      },
    );
  }
  for (final buy in [true, false]) {
    testWidgets('review the chosen order side (buy=$buy)', (tester) async {
      final market = _FreshMarket();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TradeScreen(
              marketData: market,
              walletVault: _ReviewVault(),
              walletConnect: WalletConnectService(),
              english: true,
              openWallets: () {},
              sheetMarket: market.marketsFor(MarketKind.perpetual).single,
              initialBuy: buy,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.text(buy ? 'Buy / Long' : 'Sell / Short');
      expect(button, findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '1');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.text(buy ? 'BTC · Buy / Long' : 'BTC · Sell / Short'),
        findsOneWidget,
      );
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Sign and submit'), findsNothing);
    });
  }
  testWidgets('wallet import dialog accepts a hidden recovery phrase', (
    tester,
  ) async {
    await tester.pumpWidget(
      TerminalApp(marketData: _MarketData(), walletVault: _WalletVault()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('资产与账户'));
    await tester.pumpAndSettle();
    expect(find.text('总资产估值'), findsOneWidget);
    await tester.tap(find.byTooltip('隐藏金额'));
    await tester.pumpAndSettle();
    expect(find.text('••••'), findsWidgets);
    expect(find.text('导入钱包'), findsNothing);
    await tester.tap(find.text('钱包').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导入钱包'));
    await tester.tap(find.text('导入钱包'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('输入 12 或 24 个英文单词'), findsOneWidget);
  });
}
