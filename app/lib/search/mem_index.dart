// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:_pub_shared/search/search_form.dart';
import 'package:clock/clock.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../shared/utils.dart' show boundedList;
import 'search_service.dart';
import 'text_utils.dart';
import 'token_index.dart';

final _logger = Logger('search.mem_index');
final _textSearchTimeout = Duration(milliseconds: 500);

class InMemoryPackageIndex implements PackageIndex {
  final Map<String, PackageDocument> _packages = <String, PackageDocument>{};
  final _packageNameIndex = PackageNameIndex();
  final TokenIndex _descrIndex = TokenIndex();
  final TokenIndex _readmeIndex = TokenIndex();
  final TokenIndex _apiSymbolIndex = TokenIndex();
  final TokenIndex _apiDartdocIndex = TokenIndex();
  final _likeTracker = _LikeTracker();
  final _updatedPackages = ListQueue<String>();
  final bool _alwaysUpdateLikeScores;
  DateTime? _lastUpdated;
  bool _isReady = false;

  InMemoryPackageIndex({
    math.Random? random,
    @visibleForTesting bool alwaysUpdateLikeScores = false,
  }) : _alwaysUpdateLikeScores = alwaysUpdateLikeScores;

  @override
  Future<IndexInfo> indexInfo() async {
    return IndexInfo(
      isReady: _isReady,
      packageCount: _packages.length,
      lastUpdated: _lastUpdated,
      updatedPackages: _updatedPackages.toList(),
    );
  }

  void _trackUpdated(String package) {
    while (_updatedPackages.length >= 20) {
      _updatedPackages.removeFirst();
    }
    _updatedPackages.addLast(package);
  }

  @override
  Future<void> markReady() async {
    _isReady = true;
  }

  @override
  Future<void> addPackage(PackageDocument doc) async {
    _packages[doc.package] = doc;

    // The method could be a single sync block, however, while the index update
    // happens, we are not serving queries. With the forced async segments,
    // the waiting queries will be served earlier.
    await Future.delayed(Duration.zero);
    _packageNameIndex.add(doc.package);

    await Future.delayed(Duration.zero);
    _descrIndex.add(doc.package, doc.description);

    await Future.delayed(Duration.zero);
    _readmeIndex.add(doc.package, doc.readme);

    for (ApiDocPage page in doc.apiDocPages ?? const []) {
      final pageId = _apiDocPageId(doc.package, page);
      if (page.symbols != null && page.symbols!.isNotEmpty) {
        await Future.delayed(Duration.zero);
        _apiSymbolIndex.add(pageId, page.symbols!.join(' '));
      }
      if (page.textBlocks != null && page.textBlocks!.isNotEmpty) {
        await Future.delayed(Duration.zero);
        _apiDartdocIndex.add(pageId, page.textBlocks!.join(' '));
      }
    }

    await Future.delayed(Duration.zero);
    _likeTracker.trackLikeCount(doc.package, doc.likeCount ?? 0);
    if (_alwaysUpdateLikeScores) {
      await _likeTracker._updateScores();
    } else {
      await _likeTracker._updateScoresIfNeeded();
    }

    await Future.delayed(Duration.zero);
    _lastUpdated = clock.now().toUtc();
    _trackUpdated(doc.package);
  }

  @override
  Future<void> addPackages(Iterable<PackageDocument> documents) async {
    for (PackageDocument doc in documents) {
      await addPackage(doc);
    }
    await _likeTracker._updateScores();
  }

  @override
  Future<void> removePackage(String package) async {
    final doc = _packages.remove(package);
    if (doc == null) return;
    _packageNameIndex.remove(package);
    _descrIndex.remove(package);
    _readmeIndex.remove(package);
    for (ApiDocPage page in doc.apiDocPages ?? const []) {
      final pageId = _apiDocPageId(doc.package, page);
      _apiSymbolIndex.remove(pageId);
      _apiDartdocIndex.remove(pageId);
    }
    _likeTracker.removePackage(doc.package);
    _lastUpdated = clock.now().toUtc();
    _trackUpdated('-$package');
  }

  @override
  Future<PackageSearchResult> search(ServiceSearchQuery query) async {
    final Set<String> packages = Set.from(_packages.keys);

    // filter on package prefix
    if (query.parsedQuery.packagePrefix != null) {
      final String prefix = query.parsedQuery.packagePrefix!.toLowerCase();
      packages.removeWhere(
        (package) =>
            !_packages[package]!.package.toLowerCase().startsWith(prefix),
      );
    }

    // filter on tags
    final combinedTagsPredicate =
        query.tagsPredicate.appendPredicate(query.parsedQuery.tagsPredicate);
    if (combinedTagsPredicate.isNotEmpty) {
      packages.retainWhere(
          (package) => combinedTagsPredicate.matches(_packages[package]!.tags));
    }

    // filter on dependency
    if (query.parsedQuery.hasAnyDependency) {
      packages.removeWhere((package) {
        final doc = _packages[package]!;
        if (doc.dependencies.isEmpty) return true;
        for (String dependency in query.parsedQuery.allDependencies) {
          if (!doc.dependencies.containsKey(dependency)) return true;
        }
        for (String dependency in query.parsedQuery.refDependencies) {
          final type = doc.dependencies[dependency];
          if (type == null || type == DependencyTypes.transitive) return true;
        }
        return false;
      });
    }

    // filter on points
    if (query.minPoints != null && query.minPoints! > 0) {
      packages.removeWhere((package) {
        final doc = _packages[package]!;
        return (doc.grantedPoints ?? 0) < query.minPoints!;
      });
    }

    // filter on updatedInDays
    if (query.updatedInDays != null && query.updatedInDays! > 0) {
      final threshold =
          Duration(days: query.updatedInDays!, hours: 11, minutes: 59);
      final now = clock.now();
      packages.removeWhere((package) {
        final doc = _packages[package]!;
        final diff = now.difference(doc.updated!);
        return diff > threshold;
      });
    }

    PackageHit? highlightedHit;
    if (query.considerHighlightedHit) {
      final queryText = query.parsedQuery.text;
      final matchingPackage =
          _packages[queryText] ?? _packages[queryText!.toLowerCase()];

      if (matchingPackage != null) {
        // Remove higlighted package from the final packages set.
        packages.remove(matchingPackage.package);

        // higlight only if we are on the first page
        if (query.includeHighlightedHit) {
          highlightedHit = PackageHit(package: matchingPackage.package);
        }
      }
    }

    // do text matching
    final textResults = _searchText(
      packages,
      query.parsedQuery.text,
      hasHighlightedHit: highlightedHit != null,
    );

    // filter packages that doesn't match text query
    if (textResults != null) {
      final keys = textResults.pkgScore.getKeys();
      packages.removeWhere((x) => !keys.contains(x));
    }

    late List<PackageHit> packageHits;
    switch (query.order ?? SearchOrder.top) {
      case SearchOrder.top:
        final List<Score> scores = [
          _getOverallScore(packages),
          if (textResults != null) textResults.pkgScore,
        ];
        final overallScore = Score.multiply(scores);
        packageHits = _rankWithValues(overallScore.getValues());
        break;
      case SearchOrder.text:
        final score = textResults?.pkgScore ?? Score.empty();
        packageHits = _rankWithValues(score.getValues());
        break;
      case SearchOrder.created:
        packageHits = _rankWithComparator(packages, _compareCreated);
        break;
      case SearchOrder.updated:
        packageHits = _rankWithComparator(packages, _compareUpdated);
        break;
      case SearchOrder.popularity:
        packageHits = _rankWithValues(getPopularityScore(packages));
        break;
      case SearchOrder.like:
        packageHits = _rankWithValues(getLikeScore(packages));
        break;
      case SearchOrder.points:
        packageHits = _rankWithValues(getPubPoints(packages));
        break;
    }

    // bound by offset and limit (or randomize items)
    final totalCount = packageHits.length + (highlightedHit == null ? 0 : 1);
    packageHits =
        boundedList(packageHits, offset: query.offset, limit: query.limit);

    if (textResults != null && textResults.topApiPages.isNotEmpty) {
      packageHits = packageHits.map((ps) {
        final apiPages = textResults.topApiPages[ps.package]
            // TODO: extract title for the page
            ?.map((String page) => ApiPageRef(path: page))
            .toList();
        return ps.change(apiPages: apiPages);
      }).toList();
    }

    return PackageSearchResult(
      timestamp: clock.now().toUtc(),
      totalCount: totalCount,
      highlightedHit: highlightedHit,
      packageHits: packageHits,
    );
  }

  @visibleForTesting
  Map<String, double> getPopularityScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => _packages[package]?.popularity ?? 0.0,
    );
  }

  @visibleForTesting
  Map<String, double> getLikeScore(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) => (_packages[package]?.likeCount?.toDouble() ?? 0.0),
    );
  }

  @visibleForTesting
  Map<String, double> getPubPoints(Iterable<String> packages) {
    return Map.fromIterable(
      packages,
      value: (package) =>
          (_packages[package]?.grantedPoints?.toDouble() ?? 0.0),
    );
  }

  Score _getOverallScore(Iterable<String> packages) {
    final values = Map<String, double>.fromIterable(packages, value: (package) {
      final doc = _packages[package]!;
      final downloadScore = doc.popularity ?? 0.0;
      final likeScore = _likeTracker.getLikeScore(doc.package);
      final popularity = (downloadScore + likeScore) / 2;
      final points = (doc.grantedPoints ?? 0) / math.max(1, doc.maxPoints ?? 0);
      final overall = popularity * 0.5 + points * 0.5;
      // don't multiply with zero.
      return 0.4 + 0.6 * overall;
    });
    return Score(values);
  }

  _TextResults? _searchText(
    Set<String> packages,
    String? text, {
    required bool hasHighlightedHit,
  }) {
    final sw = Stopwatch()..start();
    if (text != null && text.isNotEmpty) {
      final words = splitForQuery(text);
      if (words.isEmpty) {
        return _TextResults(Score.empty(), <String, List<String>>{});
      }

      bool aborted = false;

      bool checkAborted() {
        if (!aborted && sw.elapsed > _textSearchTimeout) {
          aborted = true;
          _logger.info(
              '[pub-aborted-search-query] Aborted text search after ${sw.elapsedMilliseconds} ms.');
        }
        return aborted;
      }

      final nameScore =
          _packageNameIndex.searchWords(words, packages: packages);

      final descr =
          _descrIndex.searchWords(words, weight: 0.90, limitToIds: packages);
      final readme =
          _readmeIndex.searchWords(words, weight: 0.75, limitToIds: packages);

      final core = Score.max([nameScore, descr, readme]);

      var symbolPages = Score.empty();
      if (!checkAborted()) {
        symbolPages = _apiSymbolIndex.searchWords(words, weight: 0.70);
      }

      // Do documentation text search only when there was no reasonable core result
      // and no reasonable API symbol result.
      var dartdocPages = Score.empty();
      final shouldSearchApiText = !hasHighlightedHit &&
          core.maxValue < 0.4 &&
          symbolPages.maxValue < 0.3;
      if (!checkAborted() && shouldSearchApiText) {
        final sw = Stopwatch()..start();
        dartdocPages = _apiDartdocIndex.searchWords(words, weight: 0.40);
        _logger.info('[pub-search-query-with-api-dartdoc-index] '
            'core: ${core.length}/${core.maxValue} '
            'symbols: ${symbolPages.length}/${symbolPages.maxValue} '
            'documentation: ${dartdocPages.length}/${dartdocPages.maxValue} '
            'elapsed: ${sw.elapsed}');
      } else {
        _logger.info('[pub-search-query-without-api-dartdoc-index] '
            'hasHighlightedHit: $hasHighlightedHit '
            'core: ${core.length}/${core.maxValue} '
            'symbols: ${symbolPages.length}/${symbolPages.maxValue}');
      }
      final logTags = [
        if (symbolPages.isNotEmpty) '[pub-search-query-api-symbols-found]',
        if (dartdocPages.isNotEmpty) '[pub-search-query-api-dartdoc-found]',
        if (!hasHighlightedHit && symbolPages.maxValue > core.maxValue)
          '[pub-search-query-api-symbols-better-than-core]',
        if (!hasHighlightedHit && dartdocPages.maxValue > core.maxValue)
          '[pub-search-query-api-dartdoc-better-than-core]',
        if (!hasHighlightedHit && symbolPages.maxValue > dartdocPages.maxValue)
          '[pub-search-query-api-dartdoc-better-than-symbols]',
      ];
      if (logTags.isNotEmpty) {
        _logger.info('[pub-search-query-api-improved] ${logTags.join(' ')}');
      }

      final apiDocScore = Score.max([symbolPages, dartdocPages]);
      final apiPackages = <String, double>{};
      for (String key in apiDocScore.getKeys()) {
        final pkg = _apiDocPkg(key);
        if (!packages.contains(pkg)) continue;
        final value = apiDocScore[key];
        apiPackages[pkg] = math.max(value, apiPackages[pkg] ?? 0.0);
      }
      final apiPkgScore = Score(apiPackages);
      var score = Score.max([core, apiPkgScore])
          .project(packages)
          .removeLowValues(fraction: 0.2, minValue: 0.01);

      // filter results based on exact phrases
      final phrases = extractExactPhrases(text);
      if (!aborted && phrases.isNotEmpty) {
        final Map<String, double> matched = <String, double>{};
        for (String package in score.getKeys()) {
          final doc = _packages[package]!;
          final bool matchedAllPhrases = phrases.every((phrase) =>
              doc.package.contains(phrase) ||
              doc.description!.contains(phrase) ||
              doc.readme!.contains(phrase));
          if (matchedAllPhrases) {
            matched[package] = score[package];
          }
        }
        score = Score(matched);
      }

      final apiDocKeys = apiDocScore.getKeys().toList()
        ..sort((a, b) => -apiDocScore[a].compareTo(apiDocScore[b]));
      final topApiPages = <String, List<String>>{};
      for (String key in apiDocKeys) {
        final pkg = _apiDocPkg(key);
        final pages = topApiPages.putIfAbsent(pkg, () => []);
        if (pages.length < 3) {
          final page = _apiDocPath(key);
          pages.add(page);
        }
      }

      return _TextResults(score, topApiPages);
    }
    return null;
  }

  List<PackageHit> _rankWithValues(Map<String, double> values) {
    final list = values.entries
        .map((e) => PackageHit(package: e.key, score: e.value))
        .toList();
    list.sort((a, b) {
      final int scoreCompare = -a.score!.compareTo(b.score!);
      if (scoreCompare != 0) return scoreCompare;
      // if two packages got the same score, order by last updated
      return _compareUpdated(_packages[a.package]!, _packages[b.package]!);
    });
    return list;
  }

  List<PackageHit> _rankWithComparator(Set<String> packages,
      int Function(PackageDocument a, PackageDocument b) compare) {
    final list = packages
        .map((package) => PackageHit(package: _packages[package]!.package))
        .toList();
    list.sort((a, b) => compare(_packages[a.package]!, _packages[b.package]!));
    return list;
  }

  int _compareCreated(PackageDocument a, PackageDocument b) {
    if (a.created == null) return -1;
    if (b.created == null) return 1;
    return -a.created!.compareTo(b.created!);
  }

  int _compareUpdated(PackageDocument a, PackageDocument b) {
    if (a.updated == null) return -1;
    if (b.updated == null) return 1;
    return -a.updated!.compareTo(b.updated!);
  }

  String _apiDocPageId(String package, ApiDocPage page) {
    return '$package::${page.relativePath}';
  }

  String _apiDocPkg(String id) {
    return id.split('::').first;
  }

  String _apiDocPath(String id) {
    return id.split('::').last;
  }
}

class _TextResults {
  final Score pkgScore;
  final Map<String, List<String>> topApiPages;

  _TextResults(this.pkgScore, this.topApiPages);
}

/// A simple (non-inverted) index designed for package name lookup.
@visibleForTesting
class PackageNameIndex {
  /// Maps package name to a reduced form of the name:
  /// the same character parts, but without `-`.
  final _namesWithoutGaps = <String, String>{};

  String _collapseName(String package) => package.replaceAll('_', '');

  void addAll(Iterable<String> packages) {
    for (final package in packages) {
      add(package);
    }
  }

  /// Add a new [package] to the index.
  void add(String package) {
    _namesWithoutGaps[package] = _collapseName(package);
  }

  /// Remove a [package] from the index.
  void remove(String package) {
    _namesWithoutGaps.remove(package);
  }

  /// Search [text] and return the matching packages with scores.
  Score search(String text) {
    return searchWords(splitForQuery(text));
  }

  /// Search using the parsed [words] and return the match packages with scores.
  Score searchWords(List<String> words, {Set<String>? packages}) {
    final pkgNamesToCheck = packages ?? _namesWithoutGaps.keys;
    final values = <String, double>{};
    for (final pkg in pkgNamesToCheck) {
      // Calculate the collapsed format of the package name based on the cache.
      // Fallback value is used in cases where concurrent updates of the index
      // would cause inconsistencies and empty value in the cache.
      final nameWithoutGaps = _namesWithoutGaps[pkg] ?? _collapseName(pkg);
      final matchedChars = List<bool>.filled(nameWithoutGaps.length, false);
      // Extra weight to compensate partial overlaps between a word and the package name.
      var matchedExtraWeight = 0;
      var unmatchedExtraWeight = 0;

      bool matchPattern(Pattern pattern) {
        var matched = false;
        pattern.allMatches(nameWithoutGaps).forEach((m) {
          matched = true;
          for (var i = m.start; i < m.end; i++) {
            matchedChars[i] = true;
          }
        });
        return matched;
      }

      for (final word in words) {
        if (matchPattern(_pluralizePattern(word))) {
          // shortcut calculations, this is a full-length prefix match
          matchedExtraWeight += word.length;
          continue;
        }
        final parts = word.length <= 3 ? [word] : ngrams(word, 3, 3).toList();
        var firstUnmatchedIndex = parts.length;
        var lastUnmatchedIndex = -1;
        for (var i = 0; i < parts.length; i++) {
          final part = parts[i];
          if (!matchPattern(part)) {
            // increase the unmatched weight
            unmatchedExtraWeight++;
            // mark the index for prefix and postfix match calculation
            firstUnmatchedIndex = math.min(i, firstUnmatchedIndex);
            lastUnmatchedIndex = i;
          }
        }
        // Add the largest of prefix or postfix match as extra weight.
        final prefixWeight = firstUnmatchedIndex;
        final postfixWeight = lastUnmatchedIndex == -1
            ? parts.length
            : (parts.length - lastUnmatchedIndex - 1);
        matchedExtraWeight += math.max(prefixWeight, postfixWeight);
      }

      final matchedCharCount = matchedChars.where((c) => c).length;
      final totalNgramCount = matchedExtraWeight + unmatchedExtraWeight;
      // The composite score combines:
      // - matched ngrams (for increasing the positive match score)
      // - (un)matched character counts (for decresing the score on missed characters)
      // As the first part is more important, the missed char weight is greatly reduced.
      const matchCharWeight = 0.2;
      final score =
          (matchedExtraWeight + (matchCharWeight * matchedCharCount)) /
              (totalNgramCount + (matchCharWeight * matchedChars.length));
      values[pkg] = score;
    }
    return Score(values).removeLowValues(fraction: 0.5, minValue: 0.5);
  }

  Pattern _pluralizePattern(String word) {
    if (word.length < 3) return word;
    if (word.endsWith('s')) {
      final singularEscaped = RegExp.escape(word.substring(0, word.length - 1));
      return RegExp('${singularEscaped}s?');
    }
    final wordEscaped = RegExp.escape(word);
    return RegExp('${wordEscaped}s?');
  }
}

class _LikeScore {
  final String package;
  int likeCount = 0;
  double score = 0.0;

  _LikeScore(this.package);
}

class _LikeTracker {
  final _values = <String, _LikeScore>{};
  bool _changed = false;
  DateTime? _lastUpdated;

  double getLikeScore(String package) {
    return _values[package]?.score ?? 0.0;
  }

  void trackLikeCount(String package, int likeCount) {
    final v = _values.putIfAbsent(package, () => _LikeScore(package));
    if (v.likeCount != likeCount) {
      _changed = true;
      v.likeCount = likeCount;
    }
  }

  void removePackage(String package) {
    final removed = _values.remove(package);
    _changed |= removed != null;
  }

  Future<void> _updateScoresIfNeeded() async {
    if (!_changed) {
      // we know there is nothing to update
      return;
    }
    final now = clock.now();
    if (_lastUpdated != null && now.difference(_lastUpdated!).inHours < 12) {
      // we don't need to update too frequently
      return;
    }

    await _updateScores();
  }

  /// Updates `_LikeScore.score` values, setting them between 0.0 (no likes) to
  /// 1.0 (most likes).
  Future<void> _updateScores() async {
    final sw = Stopwatch()..start();
    final entries = _values.values.toList();

    // The method could be a single sync block, however, while the index update
    // happens, we are not serving queries. With the forced async segments,
    // the waiting queries will be served earlier.
    await Future.delayed(Duration.zero);
    entries.sort((a, b) => a.likeCount.compareTo(b.likeCount));

    await Future.delayed(Duration.zero);
    for (int i = 0; i < entries.length; i++) {
      if (i > 0 && entries[i].likeCount == entries[i - 1].likeCount) {
        entries[i].score = entries[i - 1].score;
      } else {
        entries[i].score = (i + 1) / entries.length;
      }
    }
    _changed = false;
    _lastUpdated = clock.now();
    _logger.info('Updated like scores in ${sw.elapsed} (${entries.length})');
  }
}
