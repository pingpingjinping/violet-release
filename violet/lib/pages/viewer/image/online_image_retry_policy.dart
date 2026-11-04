import 'package:violet/component/eh/eh_provider.dart';
import 'package:violet/component/hitomi/hitomi_provider.dart';
import 'package:violet/component/image_provider.dart';

/// Network image retries are separate from page URL/header retries.
///
/// Hitomi previously used 100 bounded retries. The recursive failed-state
/// reload was removed to prevent an unbounded loop and stays disabled.
/// E-Hentai and ExHentai share a smaller, gentler retry budget.
({int retries, Duration interval}) onlineImageRetryPolicy(
  VioletImageProvider? provider,
) {
  if (provider is HitomiImageProvider) {
    return (retries: 100, interval: const Duration(milliseconds: 300));
  }
  if (provider is EHentaiImageProvider) {
    return (retries: 6, interval: const Duration(milliseconds: 500));
  }
  return (retries: 2, interval: const Duration(milliseconds: 300));
}
