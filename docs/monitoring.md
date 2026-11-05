# App 报错、接口数据和性能怎么查

现在可以直接点首页右上角的“实时 / 离线”状态，打开“诊断与日志”。先在 App 复现问题，再筛选 HTTP、WebSocket、图表或错误，展开记录查看，最后点右上角复制按钮导出 JSON。没有 Sentry 账号也能用。

这份指南以“BTC 的 15 分钟 K 线没有更新”为例。所有示范只读取行情或生成诊断事件，不签名、不下单、不转账。

## 1. 在本机启动并查看接口

以下命令在独立 App 根目录执行：

```sh
cd /Users/julian/Documents/Codex/2026-11-02/hyperliquid-testnet-terminal-app
flutter devices
```

若没有 Android 设备，先启动已有模拟器，再等设备出现在列表中。不要一直向不存在的 `emulator-5554` 运行 `flutter logs`。

```sh
flutter emulators
flutter emulators --launch hyperliquid_testnet_api36
flutter devices
```

用实际设备 ID 启动。以下开关仅在 debug 模式允许记录**公开行情**正文：

```sh
flutter run -d emulator-5554 --debug --dart-define=APP_LOG_BODIES=true
```

- 运行终端里搜索 `[HL]`。Android Studio 的 Run/Debug 控制台也可以搜索它。
- 点首页“实时”状态 → 诊断与日志 → HTTP，展开 `http.start`、`http.complete`、`http.response.body`。
- `requestId` 对应一次请求；`traceId` 把一次操作中的多个请求串起来。`durationMs` 是从发送到响应流读完的客户端耗时，包含网络、服务端和读流等待。
- 正文只观察 Hyperliquid `/info` 的公开行情白名单；账户、订单、签名、RPC 参数、跨链查询的用户参数均不记录。超过 128 KB 的正文不解析，数组预览最多 20 项，单条 data 再限制到约 8,000 字符。
- `APP_LOG_BODIES` 默认关闭；profile / release 即使传 true 也不会开启正文日志。改 `--dart-define` 后要重新运行，热重载不会改变编译期配置。

另开终端跟随已启动 App 的 Flutter 日志：

```sh
flutter logs -d emulator-5554
```

若 Flutter 工具没有连接到应用，可用 Android Logcat。命令中使用本机 SDK 的绝对路径，不依赖 `adb` 已加入 PATH：

```sh
/Users/julian/Library/Android/sdk/platform-tools/adb -s emulator-5554 logcat -v time 'flutter:I' '*:S'
```

Logcat 的单条长度有限，完整记录以 App 内复制的报告为准。不要把整个设备的未脱敏日志公开贴出；第三方插件自己的输出不经过本项目的日志入口。

## 2. 顺着一根 K 线排查

打开 BTC 详情，选择 15 分。页面调用 `MarketDataService.loadCandles`，HTTP 获取历史快照；同时 SDK 的 WebSocket 订阅接收后续蜡烛。两路数据在页面合并，再计算指标，最后交给图表绘制。

按这个顺序看诊断记录：

1. `http.start` 的 `kind=candleSnapshot`：历史请求是否发出？同 `requestId` 是否有 `http.complete`？没有 complete 可能仍在等待、响应流中断或被取消，不等于服务端没收到。
2. `chart / snapshot.accepted`：历史收到多少根、通过检查多少根？旧请求序号仍由页面过滤，换周期后迟到的快照不能覆盖当前页面。
3. `ws / subscribe.candle`：检查 `coin` 和 `interval`。离开页面会有 `unsubscribe.quote`。共享连接的状态变化会记录为 `connection`，重连由 SDK 管理。
4. `performance / window.10s`：看 `ws.candle.received`、`ws.candle.accepted`、`ws.candle.unchanged`。同一桶的累计量没有增加时，`unchanged` 增加是正常去重，不应为了“刷新”重复累加成交量。
5. `chart / candle.rejected`：非有限数、时间倒置、OHLC 价格范围非法或负成交量会被拒收。每种异常在面板里首次出现还会生成可上报错误。整份快照无有效蜡烛时显示错误，不继续画 NaN。
6. `indicatorMs` 记录最近一次全量指标计算耗时。若数据已 accepted、耗时正常但画面没变，再查控制器、可见范围与绘制；不要先重发网络请求。

报告里的 `lastCandleAt`、`lastBookAt`、`lastMidsAt` 是客户端最近收到消息的 UTC 时间，不是交易所时间，也不是蜡烛的开始时间。低成交市场可能很久没有新成交，不能仅凭 K 线安静就断言断线。SDK 内部原始 WebSocket 帧没有公开注入接口，目前记录的是 App 的类型化回调，不包含内部所有 ping、解析和重连细节。

## 3. 异常和资金结果如何区分

`FlutterError.onError` 与 `PlatformDispatcher.onError` 负责未捕获的 Flutter / Dart 异常；页面已经 catch 的错误要主动调用 `AppDiagnostics.error`。错误记录只保留类型与有限堆栈，不保留 `error.toString()`，因为异常消息可能回显完整请求或签名。

表单校验、明确拒单等预期结果保留在本地，不作为普通崩溃上报。订单和资金 service 在包装未知回报之前记录原始堆栈，方便找到出错位置。尚未逐一适配每个外部钱包的拒签错误码：未知钱包异常可能仍进入采集预算，不应据此统计“用户崩溃率”。

如果看到 `OrderOutcomeUnknown` 或资金 unknown：打开订单/资产页按已有核验流程处理。日志只帮助定位，不能证明成交或到账，也不会自动重发。`http.complete` 的 200 仅代表传输层成功，交易所业务拒绝、链上确认和最终到账仍以业务 service 的判断为准。

诊断存储与资金待核对记录是两套数据。清空诊断日志不会清空钱包或待核对订单。

## 4. 看性能，而不是只看页面是否“卡”

诊断面板每十秒采样一个窗口：

- UI / Raster P95：UI 构建和光栅化各自的耗时分布，P95 取最近最多 600 帧。`slowFrames` 按窗口内所有回调帧计数。
- 超预算判断按设备刷新率计算：60 Hz 约 16.7 ms，120 Hz 约 8.3 ms。两阶段可以流水执行，不能把 UI 与 Raster 相加后当作掉帧时间；这个统计也不等于显示器实际丢失帧数。
- `rssMb` 是整个进程当前驻留内存，包含 Dart 和原生部分，不等于 Dart heap，也不能单次判断泄漏。
- HTTP P95 是当前进程最近 100 个完成或发送失败请求的混合样本，未按接口拆分，取消的流不计。分析某接口请按 endpoint/kind 筛选原始摘要，不能用混合 P95 给交易接口设 SLA。
- WebSocket 消息和指标重算只累计次数，不逐帧写日志。切后台后停止帧采样；回前台开启新窗口。

在**真机**上用 profile 模式复现相同操作，才用于比较性能：

```sh
flutter devices
flutter run -d 替换为真机ID --profile
```

从运行终端输出的 DevTools 链接进入：

1. Performance 录制“进入 BTC → 连续拖动 → 切周期 → 返回”，点击慢帧，看 UI 还是 Raster 超时。
2. CPU Profiler 查看热点；Timeline 中搜索 `chart.indicators`，确认是不是每次推送重算占用了主 isolate。
3. Memory 先做一次稳定状态快照，重复进出图表十次，再对比 GC 后对象数量与引用链。正常缓存增加不能直接算泄漏。
4. Network 查 HTTP 请求；如果插件走原生网络栈，不保证全部显示在 Dart Network 中。

上述是排查步骤，当前模拟器的 debug 数值**不是产品性能基线**。本次没有真机性能验收，也没有据此改动指标算法。Flutter 官方说明：[Performance](https://docs.flutter.dev/tools/devtools/performance)、[CPU Profiler](https://docs.flutter.dev/tools/devtools/cpu-profiler)、[Memory](https://docs.flutter.dev/tools/devtools/memory)。

## 5. Sentry 免费版够不够

2026-11-05 核对官方定价：Developer 免费版限 1 位用户，每月有 5,000 条错误、500 万个 Span、5 GB Logs。Span 是一次性能操作的片段，不是错误事件。Team 起价 $26/月，按年付款，默认含 50,000 条错误；实际订阅金额还取决于容量和计费方式。以创建账号时的 Subscription 页面为准。[官方定价](https://sentry.io/pricing/)

额度按**事件**计算，不按不同 bug 数计算。同一个循环错误重复 5,000 次，也可能耗尽错误额度。几类数据有各自的配额；我们当前没有发送 Sentry Logs / Metrics，不能用剩余 Logs 额度抵扣错误。

达到额度以后，新的超额事件不再被接收。Sentry 明确说明这些事件会丢弃，不能排队保存，之后付费或进入新周期也无法恢复。免费 Developer 不能使用 PAYG（按量付费超额容量），若要本周期继续接收，需要升级；也可以等下一使用周期恢复。**不会因此让 App 的行情、交易或本地诊断停用**。[官方额度耗尽说明](https://www.sentry.help/en/articles/13964891-i-ve-exhausted-my-quota-what-now)

以下措施已经在 App 实现：

- 默认不配置 DSN，云端关闭；有 DSN 后上传过滤后的 Dart 错误。
- 同一错误指纹一分钟最多一次，每个进程每小时最多 20 次；这不是组织月度上限，重启会重置，多个设备还会叠加。
- 云端 trace 采样默认 0；日志、Metrics、截图、Replay、视图树和自动 breadcrumbs 关闭。
- SDK 初始化/出口抛错时降级本地。业务 HTTP 不依赖 Sentry 成功，不会因采集重发交易。
- 本地内存最多 200 条；两秒合并写入最近最多 60 条摘要，序列化最多约 64 KB。公开正文只留会话内，不落盘。存储出错时继续用内存。

因此这套方案保证的是**排障不只依赖 Sentry**，不是无限免费存储。App 被系统杀死前最后两秒可能未落盘；持续运行会覆盖老记录；卸载或清除应用数据会删除本地摘要。重要问题复现后及时复制报告。

## 6. 从没有账号到接入成功

1. 自己在 Sentry 注册组织，确认使用 Developer 免费计划。若界面先进入试用，检查到期后的计划，不能把试用额度当成永久免费额度。
2. 创建 Flutter 项目，例如 `hyperliquid-testnet-mobile`。项目设置 `Client Keys (DSN)` 复制 DSN。它用于事件接收，**不是 Auth Token**；不要在 App 里放管理 API Token。
3. 当前仓库已安装 `sentry_flutter 10.3.0`，不再执行向导去重复改入口。按下面命令提供 DSN，先使用 development 环境：

```sh
flutter run -d emulator-5554 --debug \
  --dart-define=SENTRY_DSN=替换为项目DSN \
  --dart-define=APP_ENV=development \
  --dart-define=SENTRY_TRACES_SAMPLE_RATE=0
```

4. 打开诊断面板，确认 Sentry 为 `configured`，点击“生成测试事件”。这是固定的 `DiagnosticProbe`，不会触发交易或让 App 崩溃。
5. 在 Sentry Issues 搜索 `DiagnosticProbe`，核对 environment、版本、型号和堆栈。检查事件里没有 user、request 正文、异常原始消息、变量或 breadcrumbs。**面板显示 configured、按钮点成功、SDK 返回 event ID，都不等于服务端接收成功。**
6. 如果没看到，先确认环境筛选和 DSN；再检查 Stats 的 accepted / filtered / rate_limited、Subscription 的剩余量、网络。429 可能由配额、限速或 Spike Protection 引起，不应盲目重试。[官方 429 解释](https://www.sentry.help/en/articles/13965132-why-am-i-getting-429-too-many-requests-responses-from-sentry)

确认错误采集有效且剩余量充足后，才按需求开低比例性能追踪，例如：

```sh
flutter run -d 替换为真机ID --profile \
  --dart-define=SENTRY_DSN=替换为项目DSN \
  --dart-define=APP_ENV=staging \
  --dart-define=SENTRY_TRACES_SAMPLE_RATE=0.01
```

`0.01` 是 1% 采样，不代表每月只消耗 1% 配额。该比例控制 SDK 框架性能追踪；当前自定义 HTTP P95、WS 计数和内存数据保存在本地，不会自动变成 Sentry 的云端业务看板。Sentry 10 已移除 Flutter Profiling，CPU 分析仍使用 DevTools。[Sentry 10 迁移说明](https://sentry-blog.sentry.dev/flutter-sdk-10/)

## 7. 真正遇到额度告警时怎么做

先去 `Settings → Subscription` 看当前周期和使用量，在 Stats 确定被限的是 Errors、Spans 还是其他类别。查看新增错误集中在哪个 release / operation，优先修复重复错误。Issue 自动归组不会让重复事件免计费。

免费开发阶段可以每次发布后检查使用量，并设置新 Issue 的邮件通知。以 30 天估算，5,000 条错误约等于每天 166 条；这只是容量规划，不是客户端限制。100 个设备每天各上报 2 条就可能超过月额度。客户端每小时 20 条无法保护多设备的组织总量，不能把它宣传为不会超额。

剩余量变少时的实际选择：

- **坚持零付费**：保持 traces=0，修复高频错误、增加明确的预期错误过滤；用 App 内报告继续排查，等新周期。已经丢掉的云端事件无法补回。
- **本周期必须持续收集**：升级付费容量。在 Subscription 先核对基础订阅费用，再设置 PAYG 预算/上限；如果不要按量超额，保持 PAYG 关闭或预算为 0。预算 0 只限制超额花费，不免除付费套餐本身费用。不要以为绑卡后会无限免费收集。
- **不想依赖云端配额**：保留本地报告；若未来确实需要集中长期留存，再评估自托管。自托管仍需服务器、存储、备份、升级和运维，本次没有部署，也不把它称作零成本。

Spike Protection、项目限速和容量分配是否可用依赖套餐；在对应组织界面确认后启用，不能依赖免费版一定存在这些能力。[官方配额管理](https://docs.sentry.io/pricing/quotas/)

建议上线后分别看：未捕获异常、已捕获业务异常、HTTP 失败与耗时、WS 连通性、数据拒收、资金 unknown 的数量与停留时间。未知资金状态要人工核验，不能由告警触发自动重发。目前这些云端看板与告警**尚未创建**，因为还没有 Sentry 组织；免费邮件告警也要在创建后实际验证送达。

## 8. 原生崩溃与发布符号的边界

当前接入覆盖 Flutter / Dart 错误。`enableNativeCrashHandling`、ANR、watchdog 自动上传显式关闭：原生事件不经过 Dart 的 `beforeSend` 脱敏与采集预算，不能直接宣称同样受保护。正式开启前要在 Android/iOS 原生 SDK 上实现并测试字段过滤、重复事件限额和不含钱包内容的崩溃报告，再做真机故障注入。现在遇到进程直接退出，用 Android Studio Logcat 的应用进程 / `AndroidRuntime` 过滤，或 Xcode 的设备崩溃日志定位；它们不是当前本地环形日志的一部分。

Sentry 10 的插件要求 Android API 26+、iOS 15+ 和 Apple Swift Package Manager。Android 下限已调整为 26，iOS 工程原本已有 SPM 和 iOS 15 配置。当前没有把全局 Flutter 配置改成个人机器专用设置。

发布时如果用了 `--obfuscate` 或 `--split-debug-info`，必须保存与该次包一致的 Dart 符号，并上传到 Sentry 才能还原栈。只改 release 名称不能还原代码位置。Auth Token 放本地安全环境或 CI 的 Secret，不能放进 `--dart-define` 或 Git。参考 [Flutter 的 Sentry 接入与符号说明](https://pub.dev/packages/sentry_flutter)。本次没有发布、上传符号或创建云端项目。

## 9. 对应代码及以后怎么加

从 `lib/main.dart` 进入：先 `initializeMonitoring` 恢复摘要并配置可选云端，再启动 `PerformanceMonitor`，最后挂载 `TerminalApp`。

- `lib/src/diagnostics/app_diagnostics.dart`：记录、脱敏、限额、保存、导出。持久化 key 是 `diagnostics.recent.v1`。
- `diagnostic_http_client.dart`：包住已有 http.Client；`diagnosticInfo` / `diagnosticTransport` 供 SDK 使用；资金 RPC 和 indexer 也走同一个观察器。Reown 内部网络和图标加载不在该 HTTP 覆盖范围内。
- `sentry_monitoring.dart`：可选初始化、全局错误钩子与云端字段白名单。
- `performance_monitor.dart`：帧、RSS 和十秒计数。`diagnostics_screen.dart`：查看与复制。
- `lib/src/screens/market_detail_screen.dart`：K 线边界校验、接收计数、指标计时。`lib/src/market/market_data_service.dart`：连接状态。
- `test/diagnostics_test.dart`：脱敏、容量、持久化、请求不变、错误传播、不重发、预算和帧计数。

新增功能时，沿用如下方式：操作名用固定字符串；data 只选必要公开字段；在 catch 中传入异常和堆栈；不要自行打印整个异常或钱包对象。为业务方法写中文契约注释，同时更新学习路径。金融未知回报继续保留原核验规则。

```dart
await AppDiagnostics.instance.trace('market.refresh', () async {
  try {
    await refreshMarket();
  } catch (error, stack) {
    AppDiagnostics.instance.error('market.refresh', error, stack);
    rethrow;
  }
});
```

这段是调用方式示例，`refreshMarket` 由具体功能提供。若上层已经负责记录同一错误，下层只记必要状态或设置 `remote: false`，避免重复采集。
