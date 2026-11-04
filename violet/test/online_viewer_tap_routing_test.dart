import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/viewer/widget/custom_doubletap_gesture_detector.dart';

void main() {
  testWidgets('failed image retry button receives taps before page navigation', (
    tester,
  ) async {
    var retries = 0;
    var pageTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: CustomDoubleTapGestureDectector(
              onTap: (_) => pageTaps++,
              onDoubleTap: (_) {},
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: Colors.black),
                  ),
                  Center(
                    child: IconButton(
                      key: const Key('failed-image-retry'),
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        retries++;
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('failed-image-retry')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(retries, 1);
    expect(pageTaps, 0, reason: 'retry must not trigger viewer navigation');

    await tester.tapAt(const Offset(20, 80));
    await tester.pump(const Duration(milliseconds: 250));
    expect(retries, 1);
    expect(pageTaps, 1, reason: 'ordinary viewer taps must still work');
  });

  testWidgets('double-tap gesture still reaches viewer zoom handler', (
    tester,
  ) async {
    var pageTaps = 0;
    var zooms = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: CustomDoubleTapGestureDectector(
              onTap: (_) => pageTaps++,
              onDoubleTap: (_) => zooms++,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );

    const position = Offset(50, 100);
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 250));

    expect(zooms, 1);
    expect(pageTaps, 0);
  });
}
