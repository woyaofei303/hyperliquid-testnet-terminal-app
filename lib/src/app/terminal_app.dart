// 应用外壳与共享服务的生命周期。四个主页面共享行情、钱包记录和外部钱包连接。
// 页面内的表单、周期和弹层状态由各自的 State 管理。

import 'package:flutter/material.dart';

import '../market/market_data_service.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../diagnostics/app_diagnostics.dart';
import '../screens/assets_screen.dart';
import '../screens/market_screen.dart';
import '../screens/orders_screen.dart';
import '../screens/trade_screen.dart';
import '../wallet/wallet_connect_service.dart';
import '../wallet/wallet_vault.dart';
import 'theme.dart';

/// 根组件允许注入服务，组件测试可以替换网络和设备钱包依赖。
class TerminalApp extends StatefulWidget {
  const TerminalApp({
    super.key,
    this.marketData,
    this.walletVault,
    this.walletConnect,
  });

  final MarketDataService? marketData;
  final WalletVault? walletVault;
  final WalletConnectService? walletConnect;

  @override
  State<TerminalApp> createState() => _TerminalAppState();
}

class _TerminalAppState extends State<TerminalApp> with WidgetsBindingObserver {
  // 根组件持有服务实例，并在 dispose 中释放行情连接和监听。
  late final MarketDataService _marketData;
  late final WalletVault _walletVault;
  late final WalletConnectService _walletConnect;
  int _selectedTab = 0;
  final _navigator = GlobalKey<NavigatorState>();
  bool _english = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _marketData = widget.marketData ?? MarketDataService();
    _walletVault = widget.walletVault ?? WalletVault();
    _walletConnect = widget.walletConnect ?? WalletConnectService();
    if (widget.marketData == null) _marketData.connectRealtime();
  }

  @override
  void dispose() {
    _marketData.dispose();
    _walletVault.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 离开前台即清除本地已解锁适配器，下次签名重新请求设备认证。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppDiagnostics.instance.record(
      'app',
      'lifecycle',
      data: {'state': state.name},
    );
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _walletVault.lock();
    }
  }

  /// 先选中资产主入口，再压入钱包管理路由，返回时仍落在资产页。
  void _openWallets() {
    setState(() => _selectedTab = 3);
    _navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => AssetsScreen(
          page: AssetPage.wallets,
          walletVault: _walletVault,
          walletConnect: _walletConnect,
          english: _english,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = _english
        ? const ['Market', 'Trade', 'Orders', 'Assets']
        : const ['市场', '交易', '订单与仓位', '资产与账户'];
    final screens = [
      MarketScreen(
        openWallets: _openWallets,
        walletConnect: _walletConnect,
        marketData: _marketData,
        walletVault: _walletVault,
        english: _english,
      ),
      TradeScreen(
        openWallets: _openWallets,
        active: _selectedTab == 1,
        marketData: _marketData,
        walletVault: _walletVault,
        walletConnect: _walletConnect,
        english: _english,
      ),
      OrdersScreen(
        openWallets: _openWallets,
        walletVault: _walletVault,
        marketData: _marketData,
        walletConnect: _walletConnect,
        english: _english,
      ),
      AssetsScreen(
        walletVault: _walletVault,
        walletConnect: _walletConnect,
        english: _english,
      ),
    ];

    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Hyperliquid Testnet Terminal',
      debugShowCheckedModeBanner: false,
      theme: buildTerminalTheme(),
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        overscroll: false,
      ),
      home: Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Text(
                  'H',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'HYPERLIQUID',
                        style: TextStyle(fontSize: 12, letterSpacing: 1.2),
                      ),
                      Text(
                        'TESTNET',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.accent,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _marketData,
                builder: (context, _) => Tooltip(
                  message: _english ? 'Diagnostics' : '诊断与日志',
                  child: InkWell(
                    onTap: () => _navigator.currentState!.push<void>(
                      MaterialPageRoute(
                        builder: (_) => DiagnosticsScreen(english: _english),
                      ),
                    ),
                    child: _ConnectionStatus(
                      connected: _marketData.connected,
                      english: _english,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _english ? 'Switch to Chinese' : 'Switch to English',
                onPressed: () => setState(() => _english = !_english),
                icon: const Icon(
                  Icons.translate,
                  color: AppColors.muted,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
        // 主页面保留状态；TradeScreen 的 active 会额外决定报价面板是否挂载。
        body: IndexedStack(index: _selectedTab, children: screens),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedTab,
          onDestinationSelected: (index) => setState(() {
            _selectedTab = index;
            AppDiagnostics.instance.record(
              'navigation',
              'tab',
              data: {'tab': index},
            );
          }),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.candlestick_chart_outlined),
              selectedIcon: const Icon(Icons.candlestick_chart),
              label: labels[0],
            ),
            NavigationDestination(
              icon: const Icon(Icons.swap_horiz),
              label: labels[1],
            ),
            NavigationDestination(
              icon: const Icon(Icons.receipt_long_outlined),
              selectedIcon: const Icon(Icons.receipt_long),
              label: labels[2],
            ),
            NavigationDestination(
              icon: const Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: const Icon(Icons.account_balance_wallet),
              label: labels[3],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.connected, required this.english});

  final bool connected;
  final bool english;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 7,
            color: connected ? AppColors.positive : AppColors.muted,
          ),
          const SizedBox(width: 6),
          Text(
            connected
                ? (english ? 'Live' : '实时')
                : (english ? 'Connecting' : '连接中'),
            style: const TextStyle(fontSize: 11, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}
