import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/search/search_result_window.dart';

void main() {
  test('item jump 530 retrieves exactly the previous 500 entries', () {
    final window = previousSearchWindow(530)!;
    expect(window.offset, 30);
    expect(window.count, 500);
  });

  test('remaining first 30 entries never overlap already loaded results', () {
    final window = previousSearchWindow(30)!;
    expect(window.offset, 0);
    expect(window.count, 30);
  });

  test('there is no previous window at result zero', () {
    expect(previousSearchWindow(0), isNull);
    expect(previousSearchWindow(-1), isNull);
  });

  test('regular 500-item boundary goes back to result zero', () {
    final window = previousSearchWindow(500)!;
    expect(window.offset, 0);
    expect(window.count, 500);
  });
}
