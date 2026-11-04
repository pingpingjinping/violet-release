import 'package:flutter/material.dart';

/// A recoverable state for gallery page header/URL lookup failures.
class OnlinePageLoadError extends StatelessWidget {
  final VoidCallback onRetry;
  final double? height;

  const OnlinePageLoadError({super.key, required this.onRetry, this.height});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Align(
      alignment: height == null ? Alignment.center : Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('이미지를 불러오지 못했습니다', textAlign: TextAlign.center),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    ),
  );
}
