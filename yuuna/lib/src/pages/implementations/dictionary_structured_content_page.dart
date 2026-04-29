import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_html_table/flutter_html_table.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as path;
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/models.dart';
import 'package:yuuna/utils.dart';

/// Provides and caches the processed HTML of a [DictionaryEntry] to improve
/// performance.
final dictionaryEntryHtmlProvider =
    Provider.family<String, DictionaryEntry>((ref, entry) {
  return entry.definitions
      .map((e) {
        try {
          final node =
              StructuredContent.processContent(jsonDecode(e))?.toNode();
          if (node == null) {
            return '';
          }

          final document = dom.Document.html('');
          document.body?.append(node);
          _inlineQuotedListMarkers(document);
          _suppressOuterListMarkers(document);
          final html = document.body?.innerHtml ?? '';

          return html;
        } catch (_) {
          return e.replaceAll('\n', '<br>');
        }
      })
      .toList()
      .join('<br>');
});

/// flutter_html can render CSS keyword `list-style-type` values (`disc`,
/// `circle`, `decimal`, …) but not CSS3 quoted-string markers like
/// `list-style-type: '🇯🇵 '` that Yomitan dictionaries (e.g. Jitendex) use
/// for emoji bullets. For each `<ul>`/`<ol>` whose declared marker is a
/// quoted string, prepend the literal marker text to each direct-child
/// `<li>` and switch the list style to `none` so flutter_html doesn't add a
/// fallback bullet on top.
void _inlineQuotedListMarkers(dom.Document document) {
  final quoted = RegExp(r'''^\s*['"](.*)['"]\s*$''', dotAll: true);
  for (final list in document.querySelectorAll('ul, ol')) {
    final styleAttr = list.attributes['style'];
    if (styleAttr == null || !styleAttr.contains('list-style-type')) continue;

    final declarations = styleAttr.split(';').map((d) => d.trim()).toList();
    String? markerCss;
    final remaining = <String>[];
    for (final d in declarations) {
      if (d.isEmpty) continue;
      if (d.startsWith('list-style-type')) {
        final colon = d.indexOf(':');
        if (colon != -1) markerCss = d.substring(colon + 1).trim();
      } else {
        remaining.add(d);
      }
    }
    if (markerCss == null) continue;
    final m = quoted.firstMatch(markerCss);
    if (m == null) continue;

    final markerText = m.group(1) ?? '';
    for (final li in list.children.where((c) => c.localName == 'li')) {
      li.nodes.insert(0, dom.Text(markerText));
    }
    remaining.add('list-style-type:none');
    list.attributes['style'] =
        remaining.map((d) => d.endsWith(';') ? d : '$d;').join();
  }
}

/// Hide outer markers on Jitendex's structural list wrappers — the
/// meaning-group `<ol>` (whose `<li>`s carry `data-content="sense"`) and
/// the sense-groups `<ul>` (`data-content="sense-groups"`). Both render as
/// orphan `•`/`1.` markers next to the indented inner glossary list because
/// the `<li>`'s visible content starts with another list, leaving no text
/// next to the outer marker. Driving suppression off the explicit Jitendex
/// `data-content` markers is reliable across all entries; the previous
/// structural "first child is a list" heuristic missed shapes where text
/// or wrapper elements precede the inner list.
void _suppressOuterListMarkers(dom.Document document) {
  // Walk every <li>, look at its data-content attribute directly (rather
  // than via a CSS selector which can have subtle matching edge cases).
  // If the <li> is a Jitendex sense or sense-group marker, its parent
  // <ol>/<ul> is one whose markers we want to hide. We also strip any
  // per-<li> list-style-type — Jitendex sets `listStyleType: '"①"'` etc.
  // which fall back to a default bullet in flutter_html since the package
  // can't render quoted custom markers.
  final lists = <dom.Element>{};
  int hits = 0;
  for (final li in document.querySelectorAll('li')) {
    final marker = li.attributes['data-content'];
    if (marker != 'sense' && marker != 'sense-group') continue;
    hits++;
    _stripListStyleType(li);
    final parent = li.parent;
    if (parent != null &&
        (parent.localName == 'ol' || parent.localName == 'ul')) {
      lists.add(parent);
    }
  }
  print('[YomiSplit] suppress: matched $hits sense <li>s, '
      'lists to suppress=${lists.length}');

  for (final list in lists) {
    _setListStyleType(list, 'none');
  }
}

/// Remove any `list-style-type` declaration from an element's inline style
/// attribute so it inherits from the surrounding list (where we set `none`).
void _stripListStyleType(dom.Element el) {
  final existing = el.attributes['style'];
  if (existing == null || !existing.contains('list-style-type')) return;
  final filtered = existing
      .split(';')
      .map((d) => d.trim())
      .where((d) => d.isNotEmpty && !d.startsWith('list-style-type'))
      .map((d) => d.endsWith(';') ? d : '$d;')
      .join();
  if (filtered.isEmpty) {
    el.attributes.remove('style');
  } else {
    el.attributes['style'] = filtered;
  }
}

/// Replace (or add) the `list-style-type` declaration on an element's
/// inline style.
void _setListStyleType(dom.Element el, String value) {
  final existing = el.attributes['style'] ?? '';
  final declarations = existing
      .split(';')
      .map((d) => d.trim())
      .where((d) => d.isNotEmpty && !d.startsWith('list-style-type'))
      .toList();
  declarations.add('list-style-type:$value');
  el.attributes['style'] =
      declarations.map((d) => d.endsWith(';') ? d : '$d;').join();
}

/// Get the [Directory] used as a resource directory for a certain [Dictionary].
final dictionaryResourceDirectoryProvider =
    Provider.family<Directory, int>((ref, dictionaryId) {
  final appModel = ref.watch(appProvider);

  return Directory(
      path.join(appModel.dictionaryResourceDirectory.path, '$dictionaryId'));
});

/// HTML renderer for dictionary definitions.
class DictionaryHtmlWidget extends ConsumerWidget {
  /// Create an instance of this page.
  const DictionaryHtmlWidget({
    required this.entry,
    required this.onSearch,
    super.key,
  });

  /// Dictionary entry to be rendered.
  final DictionaryEntry entry;

  /// Action to be done upon selecting the search option.
  final Function(String) onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final linkColor = Theme.of(context).colorScheme.error;
    final dictionaryFontSize = ref.read(appProvider).dictionaryFontSize;
    final fontSize = FontSize(dictionaryFontSize);
    const tableWidth = 0.3;
    final tableBorder = Border.all(color: textColor, width: tableWidth);
    final tableStyle = Style(
      border: tableBorder,
    );

    // Padding gutter for list markers — sized off the current font size so
    // it scales with the dictionary font setting. Each nesting level
    // compounds, so 2.0em per level gives clearly distinct depths
    // (~4em for nested gloss lists vs. ~2em for top-level lists).
    final listIndent = HtmlPaddings.only(left: dictionaryFontSize * 2.0);
    // flutter_html's defaults for <ul>/<ol> are `1em top + 1em bottom`,
    // which compounds heavily through Jitendex's nested gloss structure.
    // Tighten to a small fixed gap so deep nesting stays readable.
    final tightListMargin =
        Margins.symmetric(vertical: 2, unit: Unit.px);

    return DefaultTextStyle.merge(
      style: TextStyle(color: textColor),
      child: Html(
        data: ref.watch(dictionaryEntryHtmlProvider(entry)),
        shrinkWrap: true,
        onAnchorTap: (url, attributes, element) {
          onSearch.call(attributes['query'] ?? element?.text ?? 'f');
        },
        // Note: no `color` on '*' — that would override every dictionary's
        // inline `style="color:..."`. Default text color comes from the
        // surrounding DefaultTextStyle instead, leaving inline styles to win.
        style: {
          '*': Style(
            fontSize: fontSize,
          ),
          'body': Style(color: textColor),
          'td': tableStyle,
          'th': tableStyle,
          'ul': Style(padding: listIndent, margin: tightListMargin),
          'ol': Style(padding: listIndent, margin: tightListMargin),
          'li': Style(padding: HtmlPaddings.zero),
          // Make summary visually distinct since flutter_html doesn't render
          // the native disclosure triangle. Bold is enough to signal "this
          // introduces a section".
          'summary': Style(fontWeight: FontWeight.bold),
          'a': Style(color: linkColor),
        },
        extensions: [
          const TableHtmlExtension(),
          // flutter_html_table renders tables with intrinsic column widths
          // and no overflow handling, so wide tables (e.g. Jitendex's
          // "spelling and reading variants") clip past the screen. Wrap
          // every <table> in a horizontal scroll view.
          TagWrapExtension(
            tagsToWrap: {'table'},
            builder: (child) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: child,
            ),
          ),
          ImageExtension.inline(
            networkSchemas: {'jidoujisho'},
            builder: (extensionContext) => WidgetSpan(
              child: JidoujishoDictionaryImage(
                entry: entry,
                extensionContext: extensionContext,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Handles image rendering of images in a dictionary definition.
class JidoujishoDictionaryImage extends ConsumerWidget {
  /// Initialise this widget.
  const JidoujishoDictionaryImage({
    required this.entry,
    required this.extensionContext,
    super.key,
  });

  /// Dictionary entry to be rendered.
  final DictionaryEntry entry;

  /// Provides attributes for building the image.
  final ExtensionContext extensionContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final src = (extensionContext.attributes['src'] ?? '')
        .replaceFirst('jidoujisho://', '');

    final fontSize = ref.read(appProvider).dictionaryFontSize;
    final width = _parseDimension(extensionContext.attributes['width'], fontSize);
    final height =
        _parseDimension(extensionContext.attributes['height'], fontSize);

    final directory = ref
        .read(dictionaryResourceDirectoryProvider(entry.dictionary.value!.id));
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.file(
          File(path.join(directory.path, src)),
          height: height,
          width: width,
          scale: 3,
        )
      ],
    );
  }

  /// Parse a Yomitan image dimension like `"1.5em"` or `"24px"` (or a bare
  /// number) into a logical-pixel value. Yomitan dictionaries commonly
  /// declare image sizes in `em` so they scale with the user's font size; the
  /// previous parser stripped all non-digits and butchered both the unit and
  /// the decimal point.
  static double? _parseDimension(String? raw, double fontSize) {
    if (raw == null || raw.isEmpty) return null;
    final match = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*([a-zA-Z%]*)\s*$').firstMatch(raw);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    final unit = match.group(2)?.toLowerCase() ?? '';
    switch (unit) {
      case 'em':
      case 'rem':
        return value * fontSize;
      case 'px':
      case '':
      default:
        return value;
    }
  }
}

/// Special delegate for text selection from a dictionary search result.
class DictionarySelectionDelegate
    extends MultiSelectableSelectionContainerDelegate {
  /// Initialise this widget.
  DictionarySelectionDelegate({
    required this.onTextSelectionGuessLength,
  });

  /// Callback with a [JidoujishoTextSelection] which contains the text of all
  /// selectables as well as a [TextRange] representing the substring to use
  /// for dictionary search. Returns the guess length of the text selection.
  final JidoujishoTextSelection Function(JidoujishoTextSelection)
      onTextSelectionGuessLength;

  // This method is called when newly added selectable is in the current
  // selected range.
  @override
  void ensureChildUpdated(Selectable selectable) {}

  /// Handles a [JidoujishoTextSelection].
  SelectionResult handleTextSelection(
      SelectWordSelectionEvent event, JidoujishoTextSelection selection) {
    handleClearSelection(const ClearSelectionEvent());

    super.handleSelectWord(event);
    while ((getSelectedContent()?.plainText ?? '').length > 1) {
      super.handleGranularlyExtendSelection(
        const GranularlyExtendSelectionEvent(
            forward: false,
            isEnd: true,
            granularity: TextGranularity.character),
      );
    }

    final highlightLength = selection.textInside.length;

    SelectionResult? result;
    for (int i = 0; i < highlightLength - 1; i++) {
      result = super.handleGranularlyExtendSelection(
        const GranularlyExtendSelectionEvent(
          forward: true,
          isEnd: true,
          granularity: TextGranularity.character,
        ),
      );
    }

    return result ?? super.handleSelectWord(event);
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    // _expectSearchSelection = event is SelectWordSelectionEvent;
    return super.dispatchSelectionEvent(event);
  }

  //  bool _expectSearchSelection = false;
  SelectionEvent? _lastEvent;
  JidoujishoTextSelection? _guessSelection;
  JidoujishoTextSelection? _searchSelection;

  @override
  SelectionResult handleSelectWord(SelectWordSelectionEvent event) {
    if (_searchSelection != null && _lastEvent == event) {
      final selection = _searchSelection;
      _searchSelection = null;

      final startDiff = selection!.range.start - _guessSelection!.range.start;
      final endDiff = selection.range.end - _guessSelection!.range.end;

      SelectionResult? result;
      for (int i = 0; i < startDiff.abs(); i++) {
        result = super.handleGranularlyExtendSelection(
          GranularlyExtendSelectionEvent(
            forward: !startDiff.isNegative,
            isEnd: true,
            granularity: TextGranularity.character,
          ),
        );
      }

      for (int i = 0; i < endDiff.abs(); i++) {
        result = super.handleGranularlyExtendSelection(
          GranularlyExtendSelectionEvent(
            forward: !endDiff.isNegative,
            isEnd: true,
            granularity: TextGranularity.character,
          ),
        );
      }

      return result!;
    }

    super.handleSelectWord(event);
    _lastEvent = event;
    // _expectSearchSelection = true;

    if (!(currentSelectionEndIndex < selectables.length &&
        currentSelectionEndIndex >= 0)) {
      return handleClearSelection(const ClearSelectionEvent());
    }

    handleGranularlyExtendSelection(
      const GranularlyExtendSelectionEvent(
        forward: false,
        isEnd: true,
        granularity: TextGranularity.document,
      ),
    );

    handleClearSelection(const ClearSelectionEvent());

    final textBefore = getSelectedContent()?.plainText ?? '';

    super.handleSelectWord(event);
    handleGranularlyExtendSelection(
      const GranularlyExtendSelectionEvent(
        forward: true,
        isEnd: true,
        granularity: TextGranularity.document,
      ),
    );

    final textAfter = getSelectedContent()?.plainText ?? '';

    final text = '$textBefore$textAfter';

    final eventSelection = JidoujishoTextSelection(
      text: text,
      range: TextRange(
        start: textBefore.length,
        end: text.length,
      ),
    );

    late SelectionResult result;
    final guessSelection = onTextSelectionGuessLength(eventSelection);
    result = handleTextSelection(event, guessSelection);

    // onTextSelectionSearchLength(eventSelection, (searchSelection) {
    //   _guessSelection = guessSelection;
    //   _searchSelection = searchSelection;
    //   if (getSelectedContent()?.plainText == guessSelection.textInside &&
    //       searchSelection.textInside != guessSelection.textInside) {
    //     dispatchSelectionEvent(event);
    //   }
    // });

    return result;
  }
}
