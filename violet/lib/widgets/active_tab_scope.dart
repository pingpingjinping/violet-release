import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Identifies which root tab is currently allowed to start expensive work.
///
/// Tab pages remain mounted so their scroll position and state are preserved, but
/// descendants can avoid network image loading while their tab is inactive.
class ActiveTabScope extends InheritedNotifier<ValueNotifier<int>> {
  final int tabIndex;

  const ActiveTabScope({
    super.key,
    required this.tabIndex,
    required ValueNotifier<int> activeTab,
    required super.child,
  }) : super(notifier: activeTab);

  static bool isActive(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ActiveTabScope>();
    return scope == null || scope.notifier!.value == scope.tabIndex;
  }
}
