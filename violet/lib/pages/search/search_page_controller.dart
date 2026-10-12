// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';

import 'package:flare_flutter/flare_cache.dart';
import 'package:flare_flutter/flare_controls.dart';
import 'package:flare_flutter/provider/asset_flare.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get/get.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/component/hitomi/population.dart';
import 'package:violet/context/modal_bottom_sheet_context.dart';
import 'package:violet/database/query.dart';
import 'package:violet/log/log.dart';
import 'package:violet/pages/segment/filter_page_controller.dart';
import 'package:violet/pages/search/search_result_window.dart';
import 'package:violet/script/script_manager.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/thread/semaphore.dart';
import 'package:violet/util/call_once.dart';

class SearchPageController extends GetxController {
  final FlareControls heroFlareControls = FlareControls();
  late AssetFlare asset;

  FilterController filterController = FilterController(
    heroKey: 'searchtype${ModalBottomSheetContext.getCount()}',
  );

  ScrollController? scrollController;
  Map<String, GlobalKey> itemKeys = <String, GlobalKey>{};

  final List<int> _scrollQueue = <int>[];
  double _itemHeight = 0.0;
  bool _scrollInProgress = false;
  bool _queryEnd = false;
  int _searchGeneration = 0;

  var isExtended = false.obs;
  var searchPageNum = 0.obs;
  var searchTotalResultCount = 0.obs;

  final Semaphore _querySem = Semaphore(maxCount: 1);
  (SearchResult?, String)? latestQuery;
  List<QueryResult> queryResult = [];
  List<QueryResult> filterResult = [];
  int baseCount = 0; // using for user custom page index
  bool isFilterUsed = false;

  final VoidCallback reloadForce;

  SearchPageController({required this.reloadForce});

  init(BuildContext context) {
    asset = AssetFlare(
      bundle: rootBundle,
      name: 'assets/flare/search_close.flr',
    );
    cachedActor(asset);
  }

  initScroll(BuildContext context) {
    if (scrollController == null) {
      scrollController = ScrollController();
      scrollController!.addListener(scrollPositionListener);
    }
  }

  scrollPositionListener() {
    //
    // scroll position
    //
    if (itemKeys.isNotEmpty && _itemHeight <= 0.1) {
      for (var key in itemKeys.entries) {
        // invisible article is not rendered yet
        // so we can find live elements
        if (key.value.currentContext != null) {
          final bottomPadding = [
            8,
            8,
            0,
            0,
            0,
          ][Settings.searchResultType.value.index];
          _itemHeight = key.value.currentContext!.size!.height + bottomPadding;
          break;
        }
      }
    }

    if (scrollController!.offset.isNaN || _itemHeight <= 0.1) return;

    final itemPerRow = [3, 2, 1, 1, 1][Settings.searchResultType.value.index];
    const searchBarHeight = 64 + 16;
    final curI =
        ((scrollController!.offset - searchBarHeight) / _itemHeight + 1)
            .toInt() *
        itemPerRow;

    if (curI != searchPageNum.value && isExtended.value) {
      searchPageNum.value = curI;
    }

    //
    // scroll direction
    //
    var upScrolling =
        scrollController!.position.userScrollDirection ==
        ScrollDirection.forward;

    if (upScrolling) {
      _scrollQueue.add(-1);
    } else {
      _scrollQueue.add(1);
    }

    if (_scrollQueue.length > 64) {
      _scrollQueue.removeRange(0, _scrollQueue.length - 65);
    }

    var p = _scrollQueue.reduce((value, element) => value + element);

    if (p <= -32 && !isExtended.value) {
      isExtended.value = true;
    } else if (p >= 32 && isExtended.value) {
      isExtended.value = false;
    }

    //
    //  scroll lazy next query loading
    //
    if (_scrollInProgress) return;

    // A jump starts the local search at an arbitrary item offset. Fetch the
    // missing earlier results only when the user scrolls toward the top.
    if (!Settings.searchNetwork.value &&
        baseCount > 0 &&
        upScrolling &&
        scrollController!.offset <=
            scrollController!.position.viewportDimension / 2) {
      _scrollInProgress = true;
      Future.delayed(const Duration(milliseconds: 100), () async {
        try {
          await loadPreviousQuery();
        } catch (e) {
          print('loadPreviousQuery failed: $e');
        } finally {
          _scrollInProgress = false;
        }
      }).catchError((e) {
        _scrollInProgress = false;
      });
      return;
    }

    if (_queryEnd) return;
    if (scrollController!.offset >
        scrollController!.position.maxScrollExtent * 3 / 4) {
      _scrollInProgress = true;
      Future.delayed(const Duration(milliseconds: 100), () async {
        try {
          await loadNextQuery();
        } catch (e) {
          print('loadNextQuery failed: $e');
        } finally {
          _scrollInProgress = false;
        }
      }).catchError((e) {
        _scrollInProgress = false;
      });
    }
  }

  @override
  void onClose() {
    scrollController?.removeListener(scrollPositionListener);
    scrollController?.dispose();
    scrollController = null;
    itemKeys.clear();
    _scrollQueue.clear();
    super.onClose();
  }

  resetItemHeight() => _itemHeight = 0.0;

  showErrorToast(String message) {
    FToast().showToast(
      toastDuration: const Duration(seconds: 10),
      child: Container(
        padding: const EdgeInsets.all(8.0),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(),
          borderRadius: const BorderRadius.all(Radius.circular(8.0)),
        ),
        child: Text(message),
      ),
    );
  }

  loadNextQuery() async {
    final generation = _searchGeneration;
    final requestQuery = latestQuery;
    if (requestQuery == null) return;
    final acquire = _querySem.acquire();
    late final CallOnce permit;
    if (Settings.ignoreTimeout.value) {
      permit = await acquire;
    } else {
      try {
        permit = await acquire.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            showErrorToast('Semaphore acquisition failed');
            throw TimeoutException('Failed to acquire the query semaphore');
          },
        );
      } on TimeoutException {
        // Future.timeout does not cancel the original acquire. Release the
        // permit if it completes later so the semaphore cannot get stuck.
        unawaited(acquire.then<void>((latePermit) => latePermit()));
        rethrow;
      }
    }

    var releasePermit = true;
    try {
      if (generation != _searchGeneration ||
          _queryEnd ||
          (requestQuery.$1 != null && requestQuery.$1!.offset == -1)) {
        return;
      }

      final search = HentaiManager.search(
        requestQuery.$2,
        requestQuery.$1 == null ? 0 : requestQuery.$1!.offset,
        requestQuery.$1 == null ? 0 : requestQuery.$1!.next ?? 0,
      );

      late final SearchResult next;
      if (Settings.ignoreTimeout.value) {
        next = await search;
      } else {
        try {
          next = await search.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              Logger.error('[Search_loadNextQuery] Search Timeout');
              throw TimeoutException('Failed to search the query');
            },
          );
        } on TimeoutException {
          // The underlying search keeps running after Future.timeout. Keep the
          // semaphore held until it actually finishes to avoid overlapping
          // database/network searches.
          releasePermit = false;
          unawaited(
            search.then<void>(
              (_) => permit(),
              onError: (Object _, StackTrace __) => permit(),
            ),
          );
          rethrow;
        }
      }

      if (generation != _searchGeneration) return;
      latestQuery = (next, requestQuery.$2);

      if (next.results.isEmpty) {
        _queryEnd = true;
        reloadForce();
        return;
      }

      queryResult.addAll(next.results);

      if (filterController.isPopulationSort) {
        Population.sortByPopulation(queryResult);
      }

      if (searchTotalResultCount.value == 0 &&
          !latestQuery!.$2.contains('random:')) {
        Future.delayed(const Duration(milliseconds: 100)).then((value) async {
          searchTotalResultCount.value = await HentaiManager.countSearch(
            latestQuery!.$2,
          );
        });
      }

      reloadForce();

      ScriptManager.refresh();
    } catch (e, st) {
      Logger.error(
        '[search-error] E: $e\n'
        '$st',
      );
      rethrow;
    } finally {
      if (releasePermit) permit();
    }
  }

  /// Prepend local results before a user-selected Item Jump position.
  /// Network searches use cursors, so a backward offset query is not safe.
  Future<void> loadPreviousQuery() async {
    if (Settings.searchNetwork.value) return;
    final window = previousSearchWindow(baseCount);
    final requestQuery = latestQuery;
    if (window == null || requestQuery == null) return;
    if (int.tryParse(requestQuery.$2.trim()) != null) return;

    final generation = _searchGeneration;
    final expectedBase = baseCount;
    final acquire = _querySem.acquire();
    late final CallOnce permit;
    if (Settings.ignoreTimeout.value) {
      permit = await acquire;
    } else {
      try {
        permit = await acquire.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        unawaited(acquire.then<void>((latePermit) => latePermit()));
        rethrow;
      }
    }

    var releasePermit = true;
    try {
      if (generation != _searchGeneration || baseCount != expectedBase) return;
      final search = HentaiManager.search(requestQuery.$2, window.offset);
      late final SearchResult previous;
      if (Settings.ignoreTimeout.value) {
        previous = await search;
      } else {
        try {
          previous = await search.timeout(const Duration(seconds: 10));
        } on TimeoutException {
          // Do not release the semaphore while the timed-out query is active.
          releasePermit = false;
          unawaited(search.then<void>(
            (_) => permit(),
            onError: (Object _, StackTrace __) => permit(),
          ));
          rethrow;
        }
      }
      if (generation != _searchGeneration || baseCount != expectedBase) return;
      if (previous.results.length < window.count) return;

      // HentaiManager always returns 500 local results. Trim a shorter final
      // window to avoid duplicating items already present after a jump.
      final before = previous.results.take(window.count).toList();
      final controller = scrollController;
      final oldOffset = controller?.hasClients ?? false ? controller!.offset : null;
      final oldMaxExtent = controller?.hasClients ?? false
          ? controller!.position.maxScrollExtent
          : null;

      queryResult.insertAll(0, before);
      baseCount = window.offset;
      searchPageNum.value += before.length;
      if (filterController.isPopulationSort) {
        Population.sortByPopulation(queryResult);
      }
      if (isFilterUsed) applyFilter();
      reloadForce();

      if (oldOffset != null && oldMaxExtent != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scrollController?.hasClients != true) return;
          final position = scrollController!.position;
          final addedExtent = position.maxScrollExtent - oldMaxExtent;
          scrollController!.jumpTo(
            (oldOffset + (addedExtent > 0 ? addedExtent : 0)).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        });
      }
    } catch (e, st) {
      Logger.error('[search-previous-error] E: $e\n$st');
      rethrow;
    } finally {
      if (releasePermit) permit();
    }
  }

  applyFilter() {
    filterResult = filterController.applyFilter(queryResult);
    isFilterUsed = true;
  }

  doSearch([int baseCount = 0]) async {
    _searchGeneration++;
    this.baseCount = baseCount;
    _queryEnd = false;
    queryResult = [];
    filterController = FilterController(
      heroKey: 'searchtype${ModalBottomSheetContext.getCount()}',
    );
    isFilterUsed = false;
    searchTotalResultCount.value = 0;
    searchPageNum.value = 0;
    loadNextQuery();
  }

  List<QueryResult> getSearchList() {
    if (!isFilterUsed) return queryResult;
    return filterResult;
  }
}
