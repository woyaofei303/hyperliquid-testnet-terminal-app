# Hyperliquid Testnet Terminal App

这是一个独立的 Flutter 项目，和 Web 仓库分开放置。App 只连接 Hyperliquid 测试网，界面沿用 Web 的深色背景、青绿色强调色和涨跌颜色，并改成适合手机的四个底部入口。

## 从代码开始学习

按 [从零到完整流程的学习路径](docs/learning-path.md) 阅读：本地启动 → Dart 与组件 → 行情推送 → K 线 → 订单确认 → 钱包 → 资金核验 → 测试与独立改动。文档对应全部 24 个业务 Dart 文件，包含调用图、状态变化、练习和当前实现边界。

源码关键流程已补中文注释。后续新增功能的注释与文档要求见 [AGENTS.md](AGENTS.md)，变更行为时需同步更新说明。

## Web 现有功能基线

Web 已支持四类市场：永续、HIP-3、现货和 HIP-4 预测市场。用户可以查看实时行情、盘口、成交与 K 线，连接钱包后管理账户、下单、查看仓位和撤单；资产区还包括测试网存款、现货与永续余额划转、提款。Web 也包含中英文界面、订单精度和最小金额校验、报价时效校验、签名前确认，以及请求结果不明时按 cloid 查询且不自动重发。

以上基线来自 Web 项目的 [README](../hyperliquid-testnet-terminal/README.md) 与交易、资金代码。该 Web 项目没有被 App 实施修改。

## App 当前覆盖范围

- **市场**：四类市场分类、搜索和详情（预测列表目前主要为元数据，价格与推送尚未完整接入）；详情页显示 K 线、订单簿、累计深度图、近期成交和市场统计。底部的买入和卖出会打开当前币种的委托面板。K 线周期为 1m、3m、5m、15m、30m、1h、2h、4h、8h、12h、1d、3d、1w、1M，图表使用 `kline_flutter`，提供 27 个指标选项（数值尚未全部对照，KDJ 已知问题见学习路径），并添加、修改或删除水平价格线。连接钱包后，还会显示当前币种的持仓均价、委托价和保护单触发价。
- **交易**：手机上并排显示表单与盘口。点币名可以搜索或切换市场。「委托设置」中可调整有效方式、滑点或只减仓。点一档价格即可带入限价单，再检查数量和方向。窄屏和大字号模式会自动改为上下排列。支持限价单、市价单（带滑点上限）、止损市价/限价、止盈市价/限价；支持买入/做多、卖出/做空、限价有效方式和只减仓。提交前显示订单摘要，并复用 Web 的数量、价格精度和最低名义金额规则。确认前按市场类别检查 30 秒行情有效期；当前尚无通用账户余额/保证金预检查，也未在确认后再次检查时效。
- **订单与仓位**：查看账户净值、可提余额、仓位、未完成委托和近期成交；支持撤单。订单请求先保存本地 cloid，未知回报只提供核对入口，不自动重发。
- **资产与账户**：总资产估值使用交易所月度账户历史的最近一条估值（USD），月盈亏使用该区间的盈亏变化。下拉可刷新数据，点眼睛可隐藏金额；现货 USDC、永续权益、代币数量分别显示。未连接钱包时显示占位符。点「钱包」进入管理页，点右上角的历史图标查看待核验的资金操作。支持创建内置钱包、导入助记词或私钥、保存多个钱包并切换一个活跃钱包；支持连接 Reown AppKit 外部钱包。内置钱包密钥保存在系统安全存储中，首次签名前使用设备认证解锁。
- **测试网资金**：支持 Arbitrum Sepolia USDC 经 CCTP hook 存入、Hyperliquid 测试网 USDC 提款至 Arbitrum Sepolia，以及现货和永续余额划转。提交前会显示金额、网络费用与目标地址；提款重读可用余额和费用后才请求签名。App 保存交易状态，可手动核验目标链到账；未知结果不会自动重发。
- **语言与主题**：提供中英文切换，并沿用 Web 的深色与青绿色主题。

当前仍未包含高级订单中的阶梯单、TWAP、追价、移动止损、附带 TP/SL、杠杆调整，以及图表趋势线和跨页面保存绘图。账户价格线是只读叠加层，不支持拖动编辑。外部钱包连接需要本机配置 Reown Project ID，并完成原生返回链接与设备认证配置联调；当前不足项详见学习路径的“当前实现边界”。

## 环境要求

项目要求 Dart `^3.13.7`。2026-11-05 本机核对环境为 Flutter 3.47.9 stable / Dart 3.13.7；后续以 `flutter --version` 和 `dart --version` 核验，不把此处版本视为永久最新。iOS 构建需要 Xcode、Swift Package Manager 和 CocoaPods；Android 构建需要 Android SDK，安装设备要求 Android 8.0 / API 26 及以上（Sentry 10 插件要求）。

## 运行

在 App 项目根目录执行：

```sh
flutter pub get
flutter run
```

连接 Reown 外部钱包前，需要在 [Reown Dashboard](https://cloud.reown.com/) 创建 Project ID，再通过 Dart define 注入：

```sh
flutter run --dart-define=REOWN_PROJECT_ID=你的项目ID
```

没有 Project ID 时，行情仍可只读浏览，外部钱包按钮会保持不可用。内置钱包不需要 Reown 配置，但实际签名仍需设备认证能力；原生配置与真机行为尚需验收。

## 日志、异常和性能

点首页右上角“实时 / 离线”状态打开诊断面板。可筛选接口、WebSocket 和错误，复制本地报告；没有 Sentry 账号也能使用。

```sh
flutter run -d emulator-5554 --debug --dart-define=APP_LOG_BODIES=true
```

该开关只在 debug 记录公开行情正文，订单、钱包和 RPC 正文不采集。Sentry 通过 `SENTRY_DSN` 可选接入，默认关闭云端性能采样；原生崩溃自动上传尚未启用。免费额度、配置步骤、超额处理与真机性能检查见 [排障与监控指南](docs/monitoring.md)。

## 构建与检查

```sh
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build ios --no-codesign
flutter build apk
```

单元测试和模拟流程不会自动发起链上交易。CCTP calldata、提款 typed data、手续费边界和到账匹配规则有离线测试。实际签名与到账流程仍需在配置了钱包的测试设备上验收；不要将本项目的离线检查视为链上资金验证。

## 项目结构

- `lib/main.dart` 与 `lib/src/app/`：启动、共享服务生命周期、导航与主题。
- `lib/src/market/`：市场模型、测试网行情、WebSocket 订阅。
- `lib/src/chart/`：Hyperliquid 蜡烛数据适配、技术指标计算和图表指标定义。
- `lib/src/trading/`：订单校验、交易 action 构造、cloid 未确认请求核对。
- `lib/src/wallet/`：内置钱包安全存储、密钥推导和 Reown WalletConnect 适配。
- `lib/src/screens/`：市场、图表详情、交易、订单与仓位、资产与账户页面。
- `lib/src/funding/`：内部划转、CCTP 存提款和到账证据核验。
- `lib/src/diagnostics/`：本地诊断、接口观察、Dart 异常出口和性能采样。
- `docs/learning-path.md`：按一次完整使用流程串联全部模块。
- `test/`：精度规则、签名请求结构、助记词推导、图表指标与账户价格线筛选、只读入口测试。
