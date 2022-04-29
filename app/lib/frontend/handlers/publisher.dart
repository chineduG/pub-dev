// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:_pub_shared/search/search_form.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../../account/backend.dart';
import '../../audit/backend.dart';
import '../../package/search_adapter.dart';
import '../../publisher/backend.dart';
import '../../shared/handlers.dart';
import '../../shared/redis_cache.dart' show cache;
import '../../shared/tags.dart';
import '../../shared/urls.dart' as urls;
import '../request_context.dart';
import '../templates/misc.dart';
import '../templates/publisher.dart';

import 'misc.dart' show formattedNotFoundHandler;

/// Handles requests for GET /create-publisher
Future<shelf.Response> createPublisherPageHandler(shelf.Request request) async {
  if (userSessionData == null) {
    return htmlResponse(renderUnauthenticatedPage());
  }
  return htmlResponse(renderCreatePublisherPage());
}

/// Handles requests for GET /publishers
Future<shelf.Response> publisherListHandler(shelf.Request request) async {
  if (requestContext.uiCacheEnabled) {
    final content = await cache.uiPublisherListPage().get(() async {
      final page = await publisherBackend.listPublishers();
      return renderPublisherListPage(page.publishers!);
    });
    return htmlResponse(content!);
  }

  // no caching for logged-in user
  final page = await publisherBackend.listPublishers();
  final content = renderPublisherListPage(page.publishers!);
  return htmlResponse(content);
}

/// Handles requests for GET /publishers/<publisherId>
Future<shelf.Response> publisherPageHandler(
    shelf.Request request, String publisherId) async {
  checkPublisherIdParam(publisherId);
  return redirectResponse(urls.publisherPackagesUrl(publisherId));
}

/// Handles requests for GET /publishers/<publisherId>/packages [?q=...]
Future<shelf.Response> publisherPackagesPageHandler(
    shelf.Request request, String publisherId) async {
  // Redirect in case of empty search query.
  if (request.requestedUri.query == 'q=') {
    return redirectResponse(request.requestedUri.path);
  }

  // Reply with cached page if available.
  final isLanding = request.requestedUri.queryParameters.isEmpty;
  if (isLanding && requestContext.uiCacheEnabled) {
    final html = await cache.uiPublisherPackagesPage(publisherId).get();
    if (html != null) {
      return htmlResponse(html);
    }
  }

  final publisher = await publisherBackend.getPublisher(publisherId);
  if (publisher == null) {
    // We may introduce search for publishers (e.g. somebody just mistyped a
    // domain name), but now we just have a formatted error page.
    return formattedNotFoundHandler(request);
  }

  final searchForm = SearchForm.parse(
    request.requestedUri.queryParameters,
    context: SearchContext.publisher(publisherId),
  );
  // redirect to proper search page if there is any search query item present
  // TODO: remove this after a few weeks this has been released
  if (searchForm.hasNonPagination ||
      (searchForm.currentPage != null && searchForm.currentPage! > 1)) {
    final redirectForm = SearchForm.parse(request.requestedUri.queryParameters)
        .addRequiredTagIfAbsent(PackageTags.publisherTag(publisherId));
    return redirectResponse(redirectForm.toSearchLink(page: 1));
  }

  final topPackages = await searchAdapter.topFeatured(
      query: PackageTags.publisherTag(publisherId));

  final html = renderPublisherPackagesPage(
    publisher: publisher,
    topPackages: topPackages,
    searchForm: searchForm,
    isAdmin: await publisherBackend.isMemberAdmin(
        publisherId, userSessionData?.userId),
  );
  if (isLanding && requestContext.uiCacheEnabled) {
    await cache.uiPublisherPackagesPage(publisherId).set(html);
  }
  return htmlResponse(html);
}

/// Handles requests for GET /publishers/<publisherId>/admin
Future<shelf.Response> publisherAdminPageHandler(
    shelf.Request request, String publisherId) async {
  final publisher = await publisherBackend.getPublisher(publisherId);
  if (publisher == null) {
    // We may introduce search for publishers (e.g. somebody just mistyped a
    // domain name), but now we just have a formatted error page.
    return formattedNotFoundHandler(request);
  }

  if (userSessionData == null) {
    return htmlResponse(renderUnauthenticatedPage());
  }
  final isAdmin = await publisherBackend.isMemberAdmin(
    publisherId,
    userSessionData!.userId,
  );
  if (!isAdmin) {
    return htmlResponse(renderUnauthorizedPage());
  }

  return htmlResponse(renderPublisherAdminPage(
    publisher: publisher,
    members: await publisherBackend.listPublisherMembers(publisherId),
  ));
}

/// Handles requests for GET /publishers/<publisherId>/activity-log
Future<shelf.Response> publisherActivityLogPageHandler(
    shelf.Request request, String publisherId) async {
  final publisher = await publisherBackend.getPublisher(publisherId);
  if (publisher == null) {
    // We may introduce search for publishers (e.g. somebody just mistyped a
    // domain name), but now we just have a formatted error page.
    return formattedNotFoundHandler(request);
  }

  if (userSessionData == null) {
    return htmlResponse(renderUnauthenticatedPage());
  }
  final isAdmin = await publisherBackend.isMemberAdmin(
    publisherId,
    userSessionData!.userId,
  );
  if (!isAdmin) {
    return htmlResponse(renderUnauthorizedPage());
  }

  final before = auditBackend.parseBeforeQueryParameter(
      request.requestedUri.queryParameters['before']);
  final activities = await auditBackend.listRecordsForPublisher(
    publisherId,
    before: before,
  );
  return htmlResponse(renderPublisherActivityLogPage(
    publisher: publisher,
    activities: activities,
  ));
}
