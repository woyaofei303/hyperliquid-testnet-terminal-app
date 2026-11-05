// 市场列表和币种选择器共用页面。通过 pick 回调选择币种，否则打开行情详情。

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/theme.dart';
import '../market/coin_icon.dart';
import '../market/market.dart';
import '../market/market_data_service.dart';
import '../wallet/wallet_vault.dart';
import '../wallet/wallet_connect_service.dart';
import 'market_detail_screen.dart';

/// 同一列表兼作弹层选择器；pick 存在时返回市场，缺省时进入详情。
class MarketScreen extends StatefulWidget {
  const MarketScreen({
    super.key,
    required this.marketData,
    required this.walletVault,
    required this.walletConnect,
    required this.openWallets,
    this.initialKind = MarketKind.perpetual,
    this.pick,
    required this.english,
  });

  final ValueChanged<MarketTicker>? pick;
  final MarketKind initialKind;
  final MarketDataService marketData;
  final WalletVault walletVault;
  final WalletConnectService walletConnect;
  final VoidCallback openWallets;
  final bool english;

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  late MarketKind _kind = widget.initialKind;
  bool _byChange = false;
  late bool _searchOpen = widget.pick != null;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.marketData.load(_kind).ignore();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final english = widget.english;
    return AnimatedBuilder(
      animation: widget.marketData,
      builder: (context, _) {
        final allMarkets = widget.marketData.marketsFor(_kind);
        final query = _search.text.trim().toLowerCase();
        final markets =
            allMarkets.where((market) {
              return query.isEmpty ||
                  market.coin.toLowerCase().contains(query) ||
                  market.displayName.toLowerCase().contains(query);
            }).toList()..sort(
              (a, b) => _byChange
                  ? (b.changePercent ?? double.negativeInfinity).compareTo(
                      a.changePercent ?? double.negativeInfinity,
                    )
                  : (b.dayVolume ?? 0).compareTo(a.dayVolume ?? 0),
            );

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        widget.pick != null
                            ? (english ? 'Select market' : '选择市场')
                            : (english ? 'Markets' : '市场行情'),
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: english ? 'Search markets' : '搜索币种',
                        onPressed: () => setState(() {
                          _searchOpen = !_searchOpen;
                          if (!_searchOpen) _search.clear();
                        }),
                        icon: Icon(
                          _searchOpen ? Icons.search_off : Icons.search,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      for (final kind in MarketKind.values)
                        Expanded(
                          child: InkWell(
                            onTap: () => _selectKind(kind),
                            child: Container(
                              alignment: Alignment.center,
                              height: 44,
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    width: 2,
                                    color: _kind == kind
                                        ? AppColors.accent
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              child: Text(
                                english ? kind.englishName : kind.chineseName,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: _kind == kind
                                      ? AppColors.text
                                      : AppColors.muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (_searchOpen) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: english ? 'Search markets' : '搜索币种',
                        prefixIcon: const Icon(Icons.search, size: 19),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _search.clear();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close, size: 18),
                              ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(english ? 'ASSET' : '币种', style: _tableHeader),
                  ),
                  SizedBox(
                    width: 116,
                    child: Text(
                      english ? 'PRICE' : '价格',
                      textAlign: TextAlign.right,
                      style: _tableHeader,
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: InkWell(
                      onTap: () => setState(() => _byChange = !_byChange),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _byChange
                              ? (english ? 'Change ↓' : '涨幅 ↓')
                              : (english ? '24h change ⇅' : '24h 涨跌 ⇅'),
                          textAlign: TextAlign.right,
                          style: _tableHeader.copyWith(
                            color: _byChange
                                ? AppColors.accent
                                : AppColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildList(context, markets, allMarkets.length, english),
            ),
          ],
        );
      },
    );
  }

  // 加载、报错、空列表分别显示；点击数据行时传递完整市场元数据。
  Widget _buildList(
    BuildContext context,
    List<MarketTicker> markets,
    int total,
    bool english,
  ) {
    if (widget.marketData.isLoading(_kind) && total == 0) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    final error = widget.marketData.errorFor(_kind);
    if (error != null && total == 0) {
      return _EmptyState(
        message: english ? 'Market data could not be loaded.' : '暂时无法读取行情。',
        action: english ? 'Retry' : '重试',
        onPressed: () => widget.marketData.load(_kind, refresh: true).ignore(),
      );
    }
    if (markets.isEmpty) {
      return _EmptyState(
        message: english ? 'No matching markets.' : '没有匹配的币种。',
        onPressed: () => widget.marketData.load(_kind, refresh: true).ignore(),
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () => widget.marketData.load(_kind, refresh: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        itemCount: markets.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 52),
        itemBuilder: (context, index) => _MarketRow(
          market: markets[index],
          english: english,
          onTap: widget.pick != null
              ? () => widget.pick!(markets[index])
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MarketDetailScreen(
                      market: markets[index],
                      marketData: widget.marketData,
                      walletVault: widget.walletVault,
                      walletConnect: widget.walletConnect,
                      openWallets: widget.openWallets,
                      english: english,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  /// 切换分类后保留现有搜索词，并按新类别读取行情。
  void _selectKind(MarketKind kind) {
    setState(() => _kind = kind);
    widget.marketData.load(kind).ignore();
  }
}

const _tableHeader = TextStyle(
  fontSize: 10,
  color: AppColors.muted,
  letterSpacing: 0.8,
  fontWeight: FontWeight.w600,
);

class _MarketRow extends StatelessWidget {
  const _MarketRow({
    required this.market,
    required this.english,
    required this.onTap,
  });

  final MarketTicker market;
  final bool english;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final change = market.changePercent;
    final positive = (change ?? 0) >= 0;
    final color = positive ? AppColors.positive : AppColors.negative;
    return Material(
      color: AppColors.canvas,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              CoinIcon(market.iconSymbol, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      market.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _marketSubtitle(market, english),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 116,
                child: Text(
                  market.price == null
                      ? '—'
                      : NumberFormat('#,##0.########').format(market.price),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              SizedBox(
                width: 96,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: (change == null ? AppColors.muted : color)
                          .withValues(alpha: .13),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      change == null
                          ? '—'
                          : '${positive ? '+' : ''}${change.toStringAsFixed(2)}%',
                      style: TextStyle(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: change == null ? AppColors.muted : color,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _marketSubtitle(MarketTicker market, bool english) {
    final type = english ? market.kind.englishName : market.kind.chineseName;
    if (market.kind == MarketKind.hip3) return '${market.dex} · $type';
    return '${market.quote} · $type';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    this.action,
    required this.onPressed,
  });

  final String message;
  final String? action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, style: const TextStyle(color: AppColors.muted)),
        if (action != null) ...[
          const SizedBox(height: 12),
          TextButton(onPressed: onPressed, child: Text(action!)),
        ],
      ],
    ),
  );
}
