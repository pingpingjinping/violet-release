// Formatter probe for PR 15; this branch will be restored.
// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/record.dart';
import 'package:violet/locale/locale.dart';
import 'package:violet/log/log.dart';
import 'package:violet/model/article_list_item.dart';
import 'package:violet/pages/common/utils.dart';
import 'package:violet/pages/segment/card_panel.dart';
import 'package:violet/services/activity_sync.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/widgets/article_item/article_list_item_widget.dart';

class RecordArticleItem {
  final ArticleReadLog readLog;
  final QueryResult? queryResult;

  const RecordArticleItem({required this.readLog, this.queryResult});

  bool get isNotFound => queryResult == null;
}

class RecordViewPage extends StatefulWidget {
  const RecordViewPage({super.key});

  @override
  State<RecordViewPage> createState() => _RecordViewPageState();
}

class _RecordViewPageState extends State<RecordViewPage> {
  static const int _pageSize = 60;
  static const int _remoteWorkers = 4;

  final ScrollController _scrollController = ScrollController();
  final List<ArticleReadLog> _logs = [];
  final List<RecordArticleItem> _items = [];
  final Map<String, int> _itemIndexById = {};
  final Queue<ArticleReadLog> _remoteQueue = Queue<ArticleReadLog>();
  final Set<String> _queuedRemoteIds = {};

  List<QueryResult> _usableTabList = [];
  bool _initialLoading = true;
  bool _pageLoading = false;
  bool _remoteWorkersRunning = false;
  int _nextLog = 0;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadWhenNearEnd);
    ActivitySync.records.addListener(_activityChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _generation++;
    ActivitySync.records.removeListener(_activityChanged);
    _scrollController
      ..removeListener(_loadWhenNearEnd)
      ..dispose();
    super.dispose();
  }

  void _activityChanged() {
    unawaited(_reload());
  }

  void _loadWhenNearEnd() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.extentAfter <= position.viewportDimension * 2.5) {
      unawaited(_loadNextPage());
    }
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    _remoteQueue.clear();
    _queuedRemoteIds.clear();
    _remoteWorkersRunning = false;
    if (mounted) {
      setState(() {
        _initialLoading = true;
        _pageLoading = false;
        _logs.clear();
        _items.clear();
        _itemIndexById.clear();
        _usableTabList = [];
        _nextLog = 0;
      });
    }

    try {
      final user = await User.getInstance();
      final allLogs = await user.getUserLog();
      final seen = <String>{};
      final uniqueLogs = allLogs
          .where((log) => seen.add(log.articleId()))
          .toList(growable: false);
      if (!mounted || generation != _generation) return;
      _logs.addAll(uniqueLogs);
      await _loadNextPage(generation: generation);
    } catch (error, stackTrace) {
      Logger.error('[RecordViewPage] Initial load failed: $error\n$stackTrace');
      if (!mounted || generation != _generation) return;
      setState(() {
        _initialLoading = false;
        _pageLoading = false;
      });
    }
  }

  Future<void> _loadNextPage({int? generation}) async {
    final currentGeneration = generation ?? _generation;
    if (_pageLoading ||
        _nextLog >= _logs.length ||
        currentGeneration != _generation) {
      if (_initialLoading && _logs.isEmpty && mounted) {
        setState(() => _initialLoading = false);
      }
      return;
    }

    _pageLoading = true;
    if (!_initialLoading && mounted) setState(() {});
    final start = _nextLog;
    final requestedEnd = start + _pageSize;
    final end = requestedEnd < _logs.length ? requestedEnd : _logs.length;
    final page = _logs.sublist(start, end);
    var localById = <String, QueryResult>{};

    try {
      final results = await QueryManager.queryIds(
        page.map((log) => log.articleId()).toList(growable: false),
      );
      localById = {
        for (final result in results) result.id().toString(): result,
      };
    } catch (error, stackTrace) {
      Logger.error(
        '[RecordViewPage] Local page query failed: $error\n$stackTrace',
      );
    }

    if (!mounted || currentGeneration != _generation) return;
    setState(() {
      for (final log in page) {
        final id = log.articleId();
        _itemIndexById[id] = _items.length;
        _items.add(
          RecordArticleItem(readLog: log, queryResult: localById[id]),
        );
      }
      _nextLog = end;
      _initialLoading = false;
      _pageLoading = false;
      _rebuildUsableTabs();
    });

    if (!Settings.recordSearchDatabaseOnly.value) {
      for (final log in page) {
        if (localById.containsKey(log.articleId())) continue;
        if (_queuedRemoteIds.add(log.articleId())) {
          _remoteQueue.add(log);
        }
      }
      _startRemoteWorkers(currentGeneration);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          currentGeneration != _generation ||
          !_scrollController.hasClients) {
        return;
      }
      if (_scrollController.position.maxScrollExtent <=
          _scrollController.position.viewportDimension * 2.5) {
        unawaited(_loadNextPage(generation: currentGeneration));
      }
    });
  }

  void _rebuildUsableTabs() {
    _usableTabList = _items
        .map((item) => item.queryResult)
        .whereType<QueryResult>()
        .toList(growable: false);
  }

  void _startRemoteWorkers(int generation) {
    if (_remoteWorkersRunning ||
        _remoteQueue.isEmpty ||
        generation != _generation) {
      return;
    }
    _remoteWorkersRunning = true;
    unawaited(_drainRemoteQueue(generation));
  }

  Future<void> _drainRemoteQueue(int generation) async {
    Future<void> worker() async {
      while (mounted && generation == _generation) {
        if (_remoteQueue.isEmpty) return;
        final log = _remoteQueue.removeFirst();
        try {
          final search = await HentaiManager.idSearch(log.articleId());
          if (search.results.isEmpty) continue;
          final source = search.results.first;
          final result = QueryResult(
            result: {
              'Id': int.parse(log.articleId()),
              'Title': source.title(),
              'EHash': source.ehash(),
              'Type': source.type(),
              'Artists': source.artists(),
              'Characters': source.characters(),
              'Groups': source.groups(),
              'Language': source.language(),
              'Series': source.series(),
              'Tags': source.tags(),
              'Uploader': source.uploader(),
              'PublishedEH': source.publishedeh(),
              'Files': source.files(),
              'Thumbnail': source.thumbnail(),
              'URL': source.url(),
            },
          );
          if (!mounted || generation != _generation) return;
          final index = _itemIndexById[log.articleId()];
          if (index == null || _items[index].queryResult != null) continue;
          setState(() {
            _items[index] = RecordArticleItem(
              readLog: log,
              queryResult: result,
            );
          });
        } catch (error, stackTrace) {
          Logger.error(
            '[RecordViewPage] Article not found: '
            '${log.articleId()}\n$error\n$stackTrace',
          );
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(_remoteWorkers, (_) => worker()),
    );
    if (!mounted || generation != _generation) return;
    _remoteWorkersRunning = false;
    setState(_rebuildUsableTabs);
    if (_remoteQueue.isNotEmpty) _startRemoteWorkers(generation);
  }

  @override
  Widget build(BuildContext context) {
    final child = _initialLoading
        ? const Center(
            child: CircularProgressIndicator(
              color: Colors.blue,
              strokeWidth: 4,
            ),
          )
        : _buildRecords(context);
    return CardPanel.build(
      context,
      child: child,
      enableBackgroundColor: true,
    );
  }

  Widget _buildRecords(BuildContext context) {
    final windowWidth = MediaQuery.of(context).size.width;
    final columnCount =
        MediaQuery.of(context).orientation == Orientation.landscape ? 4 : 3;
    final itemWidth = (windowWidth - 4.0 - 48) / columnCount;

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.all(8),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columnCount,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 3 / 4,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final item = _items[index];
                return Padding(
                  key: ValueKey('record/${item.readLog.articleId()}'),
                  padding: EdgeInsets.zero,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        item.isNotFound
                            ? RecordArticleNotFoundItem(
                                articleId: item.readLog.articleId(),
                                width: itemWidth,
                              )
                            : Provider<ArticleListItem>.value(
                                value: ArticleListItem.fromArticleListItem(
                                  queryResult: item.queryResult!,
                                  addBottomPadding: false,
                                  showDetail: false,
                                  width: itemWidth,
                                  thumbnailTag:
                                      'record/${item.readLog.articleId()}',
                                  usableTabList: _usableTabList,
                                ),
                                child: const ArticleListItemWidget(),
                              ),
                      ],
                    ),
                  ),
                );
              },
              childCount: _items.length,
            ),
          ),
        ),
        if (_pageLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

class RecordArticleNotFoundItem extends StatelessWidget {
  final String articleId;
  final double width;

  const RecordArticleNotFoundItem({
    super.key,
    required this.articleId,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(3)),
      onTap: () {
        final id = int.tryParse(articleId);
        if (id == null) return;
        showArticleInfoNotFound(
          context,
          id,
          title: Translations.instance!.trans('articlenotfound'),
        );
      },
      child: SizedBox(
        width: width,
        height: width * 4 / 3,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.3),
            borderRadius: const BorderRadius.all(Radius.circular(3)),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.withValues(alpha: 0.18),
                spreadRadius: 3,
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ),
    );
  }
}
