// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_pub_shared/data/page_data.dart';
import 'package:_pub_shared/search/search_form.dart';

import '../../account/backend.dart' show userSessionData;
import '../../service/announcement/backend.dart';
import '../../shared/configuration.dart';
import '../../shared/urls.dart' as urls;

import '../dom/dom.dart' as d;
import '../static_files.dart';

import '_consts.dart';

import 'views/shared/layout.dart';
import 'views/shared/search_banner.dart';
import 'views/shared/site_header.dart';

enum PageType {
  error,
  account,
  landing,
  listing,
  package,
  publisher,
  standalone,
}

/// Whether to show a wide/tall search banner at the top of the page,
/// otherwise only show a top-navigation search input.
bool showSearchBanner(PageType type) =>
    type != PageType.account &&
    type != PageType.package &&
    type != PageType.publisher &&
    type != PageType.standalone;

/// Renders the layout page template.
String renderLayoutPage(
  PageType type,
  d.Node contentNode, {
  required String title,
  String? pageDescription,
  String? faviconUrl,

  /// The canonical content link that will be put in the header.
  /// https://support.google.com/webmasters/answer/139066?hl=en
  String? canonicalUrl,
  String? publisherId,
  SearchForm? searchForm,
  bool noIndex = false,
  PageData? pageData,
  List<String>? mainClasses,
}) {
  // normalize canonical URL
  if (canonicalUrl != null && canonicalUrl.startsWith('/')) {
    canonicalUrl = '${urls.siteRoot}$canonicalUrl';
  }
  mainClasses ??= ['container'];
  final isRoot = type == PageType.landing;
  final bodyClasses = [
    if (type == PageType.standalone) 'page-standalone',
    if (type == PageType.landing) 'page-landing',
  ];
  final announcementBannerHtml = announcementBackend.getAnnouncementHtml();
  return pageLayoutNode(
    title: title,
    description: pageDescription ?? _defaultPageDescription,
    canonicalUrl: canonicalUrl,
    faviconUrl: faviconUrl ?? staticUrls.smallDartFavicon,
    noIndex: noIndex,
    oauthClientId: activeConfiguration.pubSiteAudience,
    pageDataEncoded:
        pageData == null ? null : pageDataJsonCodec.encode(pageData.toJson()),
    bodyClasses: bodyClasses,
    siteHeader: siteHeaderNode(
      pageType: type,
      userSession: userSessionData,
    ),
    announcementBanner: announcementBannerHtml == null
        ? null
        : d.unsafeRawHtml(announcementBannerHtml),
    searchBanner: showSearchBanner(type)
        ? _renderSearchBanner(
            type: type,
            publisherId: publisherId,
            searchForm: searchForm,
          )
        : null,
    isLanding: type == PageType.landing,
    landingBlurb: defaultLandingBlurbNode,
    mainClasses: mainClasses,
    mainContent: contentNode,
    includeHighlightJs: type == PageType.package,
    schemaOrgSearchActionJson: isRoot ? _schemaOrgSearchAction : null,
  ).toString();
}

d.Node _renderSearchBanner({
  required PageType type,
  required String? publisherId,
  required SearchForm? searchForm,
}) {
  final queryText = searchForm?.query;
  String? searchPlaceholder;
  if (publisherId != null) {
    searchPlaceholder ??= 'Search $publisherId packages';
  } else {
    searchPlaceholder ??= getSdkDict(null).searchPackagesLabel;
  }
  final searchFormUrl = publisherId == null
      ? urls.searchUrl()
      : urls.publisherPackagesUrl(publisherId);
  final searchSort = searchForm?.order?.name;
  return searchBannerNode(
    // When search is active (query text has a non-empty value) users may expect
    // to scroll through the results via keyboard. We should only autofocus the
    // search field when there is no active search.
    autofocus: queryText == null,
    showSearchFiltersButton: type == PageType.listing,
    formUrl: searchFormUrl,
    placeholder: searchPlaceholder,
    queryText: queryText,
    sortParam: searchSort,
    hasActive: searchForm?.hasActiveNonQuery ?? false,
  );
}

final String _defaultPageDescription =
    'Pub is the package manager for the Dart programming language, containing reusable '
    'libraries & packages for Flutter, AngularDart, and general Dart programs.';

const _schemaOrgSearchAction = {
  '@context': 'http://schema.org',
  '@type': 'WebSite',
  'url': '${urls.siteRoot}/',
  'potentialAction': {
    '@type': 'SearchAction',
    'target': '${urls.siteRoot}/packages?q={search_term_string}',
    'query-input': 'required name=search_term_string',
  },
};
