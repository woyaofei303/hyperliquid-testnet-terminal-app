// 币种图标共用入口。常用图标随包安装，其余从 Hyperliquid 图标源读取。

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app/theme.dart';

/// 在列表、详情和资产行复用图标，加载失败保持占位尺寸以避免布局跳动。
class CoinIcon extends StatelessWidget {
  const CoinIcon(this.symbol, {super.key, this.size = 28});

  final String? symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    // 去掉报价币、DEX 前缀和 k 倍数前缀，只用基础币名匹配图标源。
    final base = (symbol ?? '')
        .split('/')
        .first
        .split(':')
        .last
        .replaceFirst(RegExp(r'^k(?=[A-Z])'), '');
    final fallback = ColoredBox(
      color: AppColors.surface,
      child: Center(
        child: Icon(
          symbol == null ? Icons.query_stats : Icons.token_outlined,
          size: size * .63,
          color: AppColors.muted,
        ),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: ClipOval(
          child: ColoredBox(
            color: const Color(0xffe0e8e8),
            child: const {'BTC', 'ETH', 'SOL', 'HYPE'}.contains(base)
                ? SvgPicture.asset('assets/coins/$base.svg')
                : base.isEmpty || base.startsWith('@') || base.startsWith('#')
                ? fallback
                : SvgPicture.network(
                    Uri.https(
                      'app.hyperliquid.xyz',
                      '/coins/$base.svg',
                    ).toString(),
                    placeholderBuilder: (_) => fallback,
                    errorBuilder: (_, _, _) => fallback,
                  ),
          ),
        ),
      ),
    );
  }
}
