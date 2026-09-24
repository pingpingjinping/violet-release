// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:collection';

import 'package:violet/component/image_provider.dart';

class ProviderManager {
  static final HashMap<int, VioletImageProvider> _ids =
      HashMap<int, VioletImageProvider>();
  static final HashMap<int, bool> _dirty = HashMap<int, bool>();

  static bool isExists(int id) {
    return _ids.containsKey(id);
  }

  static void insert(int id, VioletImageProvider url) {
    _dirty[id] = false;
    _ids[id] = url;
  }

  static VioletImageProvider getIgnoreDirty(int id) {
    return _ids[id]!;
  }

  static Future<VioletImageProvider> get(int id) async {
    final provider = _ids[id]!;
    if (_dirty[id] == true) {
      // Keep the provider dirty until refresh completes successfully.
      // A transient refresh failure must not turn a cached gallery into a
      // permanently empty/clean provider for the rest of the app session.
      await provider.refresh();
      _dirty[id] = false;
    }
    return provider;
  }

  static bool dirty(int id) {
    return _dirty[id] ?? false;
  }

  static void clear() {
    _ids.clear();
    _dirty.clear();
  }

  static void checkMustRefresh() {
    for (var v in _dirty.entries) {
      if (_ids[v.key]!.isRefreshable()) _dirty[v.key] = true;
    }
  }

  static Future<void> refresh(int id, List<bool> target) async {
    await _ids[id]!.refreshPartial(target);
    _dirty[id] = true;
  }
}
