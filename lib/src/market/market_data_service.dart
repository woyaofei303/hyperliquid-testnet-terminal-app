// 行情共享服务。HTTP 读取市场元数据和快照，WebSocket 更新列表价格。
// 单个币种的盘口、成交和蜡烛订阅由 MarketQuotePanel 管理。

import '../diagnostics/app_diagnostics.dart';
import '../diagnostics/diagnostic_http_client.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hyperliquid_dart/hyperliquid_dart.dart';

import 'market.dart';

/// 集中缓存各类市场，notifyListeners 驱动列表及交易标题重建。
class MarketDataService extends ChangeNotifier {
  MarketDataService({InfoClient? info, WebSocketClient? websocket})
    : _info = info ?? diagnosticInfo(),
      realtime = websocket ?? WebSocketClient(isTestnet: true);

  final InfoClient _info;
  final WebSocketClient realtime;
  final Map<MarketKind, List<MarketTicker>> _cache = {};
  final Map<MarketKind, Object> _errors = {};
  final Set<MarketKind> _loading = {};
  final Map<MarketKind, DateTime> _updatedAt = {};
  final List<SubscriptionHandle> _subscriptions = [];
  bool _connected = false;
  bool _connecting = false;
  bool _disposed = false;
  StreamSubscription<WsConnectionState>? _connection;

  bool get connected => _connected;
  bool isLoading(MarketKind kind) => _loading.contains(kind);
  Object? errorFor(MarketKind kind) => _errors[kind];
  List<MarketTicker> marketsFor(MarketKind kind) =>
      List.unmodifiable(_cache[kind] ?? const []);

  /// 按市场类别判断 30 秒行情窗口；当前粒度是类别，并非每个币种单独计时。
  bool hasFreshPrice(MarketKind kind) {
    final updated = _updatedAt[kind];
    return updated != null &&
        DateTime.now().difference(updated) <= const Duration(seconds: 30);
  }

  int? assetIdFor(String coin) {
    for (final market in _cache.values.expand((markets) => markets)) {
      if (market.coin == coin) return market.assetId;
    }
    return null;
  }

  /// 命中缓存时直接返回；refresh 才重新读取。错误留给页面显示，finally 结束加载态。
  Future<List<MarketTicker>> load(
    MarketKind kind, {
    bool refresh = false,
  }) async {
    if (!refresh && _cache.containsKey(kind)) return marketsFor(kind);
    _loading.add(kind);
    _errors.remove(kind);
    notifyListeners();
    try {
      final markets = switch (kind) {
        MarketKind.perpetual => await _loadPerpetuals(),
        MarketKind.hip3 => await _loadHip3(),
        MarketKind.spot => await _loadSpot(),
        MarketKind.outcome => await _loadOutcomes(),
      };
      _cache[kind] = markets;
      _updatedAt[kind] = DateTime.now();
      return marketsFor(kind);
    } catch (error, stack) {
      AppDiagnostics.instance.error('market.load', error, stack);
      _errors[kind] = error;
      rethrow;
    } finally {
      _loading.remove(kind);
      notifyListeners();
    }
  }

  /// 永续资产编号来自 universe 的位置，不能在过滤或排序后重新编号。
  Future<List<MarketTicker>> _loadPerpetuals() async {
    final response = await _info.metaAndAssetCtxs();
    return [
      for (var i = 0; i < response.universe.length; i++)
        if (response.universe[i].isDelisted != true)
          MarketTicker(
            coin: response.universe[i].name,
            kind: MarketKind.perpetual,
            price: parseMarketNumber(_contextAt(response.assetCtxs, i)?.markPx),
            previousPrice: parseMarketNumber(
              _contextAt(response.assetCtxs, i)?.prevDayPx,
            ),
            dayVolume: parseMarketNumber(
              _contextAt(response.assetCtxs, i)?.dayNtlVlm,
            ),
            sizeDecimals: response.universe[i].szDecimals,
            assetId: i,
            base: response.universe[i].name,
          ),
    ];
  }

  /// HIP-3 订单编号组合 DEX 序号和该 DEX 内的资产位置，名称保留 DEX 前缀。
  Future<List<MarketTicker>> _loadHip3() async {
    final dexs = await _info.perpDexs();
    final responses = await Future.wait(
      dexs.map(
        (dex) async => (dex, await _info.metaAndAssetCtxs(dex: dex.name)),
      ),
    );
    final markets = <MarketTicker>[];
    for (var dexIndex = 0; dexIndex < responses.length; dexIndex++) {
      final (dex, response) = responses[dexIndex];
      for (var i = 0; i < response.universe.length; i++) {
        final asset = response.universe[i];
        if (asset.isDelisted == true) continue;
        final context = _contextAt(response.assetCtxs, i);
        markets.add(
          MarketTicker(
            coin: asset.name.contains(':')
                ? asset.name
                : '${dex.name}:${asset.name}',
            kind: MarketKind.hip3,
            price: parseMarketNumber(context?.markPx),
            previousPrice: parseMarketNumber(context?.prevDayPx),
            dayVolume: parseMarketNumber(context?.dayNtlVlm),
            sizeDecimals: asset.szDecimals,
            assetId: 100000 + (dexIndex + 1) * 10000 + i,
            base: asset.name.split(':').last,
            dex: dex.name,
          ),
        );
      }
    }
    return markets;
  }

  Future<List<MarketTicker>> _loadSpot() async {
    final response = await _info.spotMetaAndAssetCtxs();
    final tokens = {
      for (final token in response.meta.tokens) token.index: token,
    };
    final contexts = {
      for (final context in response.assetCtxs) context.coin: context,
    };
    return [
      for (final pair in response.meta.universe)
        if (pair.tokens.length > 1 &&
            tokens[pair.tokens.first] != null &&
            tokens[pair.tokens[1]] != null)
          _spotTicker(pair, tokens, contexts),
    ];
  }

  // 现货配对的 API 名称和展示名分别保存，资产编号使用 10000 加配对 index。
  MarketTicker _spotTicker(
    SpotUniverse pair,
    Map<int, SpotToken> tokens,
    Map<String, SpotAssetContext> contexts,
  ) {
    final base = tokens[pair.tokens.first]!;
    final quote = tokens[pair.tokens[1]]!;
    final context = contexts[pair.name];
    return MarketTicker(
      coin: pair.name,
      kind: MarketKind.spot,
      price: parseMarketNumber(context?.midPx ?? context?.markPx),
      previousPrice: parseMarketNumber(context?.prevDayPx),
      dayVolume: parseMarketNumber(context?.dayNtlVlm),
      sizeDecimals: base.szDecimals,
      assetId: 10000 + pair.index,
      base: base.name,
      quote: quote.name,
      label: '${base.name}/${quote.name}',
    );
  }

  /// 读取预测市场及前两个方向的元数据；本方法不补价格，空价格必须保持未知。
  Future<List<MarketTicker>> _loadOutcomes() async {
    final response = await _info.outcomeMeta();
    final markets = <MarketTicker>[];
    for (final outcome in response.outcomes) {
      final title = outcome.name.isEmpty
          ? 'Outcome ${outcome.outcome}'
          : outcome.name;
      for (var side = 0; side < outcome.sideSpecs.length && side < 2; side++) {
        final encoding = outcome.outcome * 10 + side;
        final sideName = outcome.sideSpecs[side].name;
        markets.add(
          MarketTicker(
            coin: '#$encoding',
            kind: MarketKind.outcome,
            price: null,
            previousPrice: null,
            dayVolume: null,
            sizeDecimals: 0,
            assetId: 100000000 + encoding,
            base: sideName,
            quote: outcome.quoteToken,
            label: '$title · $sideName',
            outcomeId: outcome.outcome,
            outcomeSide: side,
          ),
        );
      }
    }
    return markets;
  }

  AssetContext? _contextAt(List<AssetContext> values, int index) =>
      index < values.length ? values[index] : null;

  /// 连接状态由 SDK 通知同步；本服务只注册一组订阅，重连仍由 SDK 管理。
  Future<void> connectRealtime() async {
    if (_disposed || _connecting || _subscriptions.isNotEmpty) return;
    _connecting = true;
    _connection ??= realtime.stateChanges.listen((state) {
      AppDiagnostics.instance.record(
        'ws',
        'connection',
        data: {'state': state.name},
      );
      AppDiagnostics.instance.metrics['wsState'] = state.name;
      if (_disposed) return;
      _connected = state == WsConnectionState.connected;
      notifyListeners();
    });
    try {
      await realtime.connect();
      if (_disposed) return;
      _subscriptions.add(realtime.subscribeAllMids(_applyPerpetualMids));
      _subscriptions.add(realtime.subscribeSpotAssetCtxs(_applySpotContexts));
      _connected = true;
      notifyListeners();
    } catch (error, stack) {
      AppDiagnostics.instance.error('ws.connect', error, stack);
      _connected = false;
      if (!_disposed) notifyListeners();
    } finally {
      _connecting = false;
    }
  }

  void _applyPerpetualMids(Map<String, String> mids) {
    AppDiagnostics.instance.count('ws.mids');
    AppDiagnostics.instance.metrics['lastMidsAt'] = DateTime.now()
        .toUtc()
        .toIso8601String();
    _updatedAt[MarketKind.perpetual] = DateTime.now();
    _updatedAt[MarketKind.hip3] = DateTime.now();
    _updatePrices(MarketKind.perpetual, mids);
    _updatePrices(MarketKind.hip3, mids);
  }

  void _applySpotContexts(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is! Map) return;
    final contexts = data['ctxs'];
    if (contexts is! List) return;
    _updatedAt[MarketKind.spot] = DateTime.now();
    final prices = <String, String>{};
    for (final entry in contexts.whereType<Map>()) {
      final coin = entry['coin'];
      final mid = entry['midPx'] ?? entry['markPx'];
      if (coin is String && mid is String) prices[coin] = mid;
    }
    _updatePrices(MarketKind.spot, prices);
  }

  /// 仅替换能解析为有限正数的价格，并保留未出现在本次推送中的市场。
  void _updatePrices(MarketKind kind, Map<String, String> prices) {
    final markets = _cache[kind];
    if (markets == null) return;
    var changed = false;
    final updated = <MarketTicker>[];
    for (final market in markets) {
      final price = _positive(prices[market.coin]);
      if (price == null) {
        updated.add(market);
      } else {
        changed = true;
        updated.add(market.withPrice(price));
      }
    }
    _cache[kind] = updated;
    if (changed) notifyListeners();
  }

  double? _positive(String? value) {
    final parsed = double.tryParse(value ?? '');
    return parsed != null && parsed.isFinite && parsed > 0 ? parsed : null;
  }

  /// 请求约 300 个周期的历史窗口；月份在查询窗口中按 30 天估算。
  Future<List<Candle>> loadCandles(String coin, String interval) {
    final end = DateTime.now().millisecondsSinceEpoch;
    final start = end - _intervalMilliseconds(interval) * 300;
    return _info.candleSnapshot(
      coin: coin,
      interval: interval,
      startTime: start,
      endTime: end,
    );
  }

  Future<L2Book> loadOrderBook(String coin) => _info.l2Book(coin: coin);

  Future<List<Trade>> loadRecentTrades(String coin) => _info.recentTrades(coin);

  int _intervalMilliseconds(String interval) {
    final amount = int.parse(interval.substring(0, interval.length - 1));
    return amount *
        switch (interval.substring(interval.length - 1)) {
          'm' => 60000,
          'h' => 3600000,
          'd' => 86400000,
          'w' => 604800000,
          'M' => 2592000000,
          _ => throw FormatException('Unsupported interval: $interval'),
        };
  }

  /// 先取消本服务订阅，再关闭 WebSocket 和 HTTP 客户端。
  Future<void> disposeConnections() async {
    _disposed = true;
    await _connection?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await realtime.dispose();
    _info.close();
  }

  @override
  void dispose() {
    unawaited(disposeConnections());
    super.dispose();
  }
}
