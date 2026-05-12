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

/// Match a CSS quoted-string `list-style-type` value such as `'①'`, `"🇯🇵 "`,
/// etc. The captured group is the inner text between the quotes.
final RegExp _quotedListStyleRegex =
    RegExp(r'''^\s*['"](.*)['"]\s*$''', dotAll: true);

/// Jitendex `data-content` markers we treat as semantic callouts in the
/// renderer. Anything not in this set falls through to default flutter_html
/// rendering. Verified against `term_bank_*.json` from
/// jitendex.org/jitendex-yomitan.zip (April 2026 build):
///   * sense notes are wrapped in `<div data-content="sense-note">`
///   * example sentences are `<div data-content="example-sentence">`
///   * cross-references are `<div data-content="xref">` (each contains a
///     header `xref-content` div with the linked term and a `xref-glossary`
///     preview line — both render inside our box for free)
/// We deliberately do NOT match `extra-info` — that's a generic supplementary
/// wrapper Jitendex uses around the entire sense body (note + examples +
/// references), so styling it as a single callout would swallow everything
/// inside.
const Set<String> _exampleSentenceMarkers = {'example-sentence'};
const Set<String> _noteMarkers = {'sense-note'};
const Set<String> _seeAlsoMarkers = {'xref'};

/// Fixed gutter width applied to the sense marker cell (`<span>` wrapping
/// `①`) and the left padding of every subsequent gloss line. Both use the
/// same value so the hanging indent lines up exactly. 1.5em is just wide
/// enough to comfortably hold a single full-width CJK marker glyph plus a
/// touch of trailing whitespace.
const String _glossIndent = '1.5em';

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
          // _addSenseSpacing must run BEFORE _flattenSenseLists — the latter
          // replaces <li> with <div>, and we want the margin-bottom inline
          // style to be carried through onto the new <div>.
          _addSenseSpacing(document);
          _flattenSenseLists(document);
          _styleJitendexInlineMarkers(document);
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
    final m = _quotedListStyleRegex.firstMatch(markerCss);
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

/// Read an element's `list-style-type` declaration. Returns the raw
/// declaration value (e.g. `'①'`, `disc`) or `null` if the element doesn't
/// declare one.
String? _readListStyleType(dom.Element el) {
  final style = el.attributes['style'];
  if (style == null || !style.contains('list-style-type')) return null;
  for (final d in style.split(';')) {
    final trimmed = d.trim();
    if (!trimmed.startsWith('list-style-type')) continue;
    final colon = trimmed.indexOf(':');
    if (colon == -1) return null;
    return trimmed.substring(colon + 1).trim();
  }
  return null;
}

/// Append a CSS declaration to an element's inline `style` attribute,
/// preserving any existing declarations.
void _appendInlineStyle(dom.Element el, String declaration) {
  final existing = el.attributes['style'];
  final stripped = declaration.endsWith(';') ? declaration : '$declaration;';
  if (existing == null || existing.isEmpty) {
    el.attributes['style'] = stripped;
    return;
  }
  el.attributes['style'] =
      existing.endsWith(';') ? '$existing$stripped' : '$existing;$stripped';
}

/// Convert Jitendex's structural sense + glossary lists into a tree of
/// `<div>`s so flutter_html doesn't draw orphan `1.`/`•` markers.
///
/// Each `<li data-content="sense">` carries a quoted `list-style-type`
/// (Jitendex sets `'①'`, `'②'`, … per item). We capture the quoted text and
/// inline it on the FIRST `<li>` of the inner `<ul data-content="glossary">`
/// so the marker sits next to the first gloss line (Yomitan-style top
/// alignment) rather than floating on its own line above the gloss block.
/// If there's no glossary list (e.g., interjection senses), the marker
/// falls back to a leading text node on the sense itself.
///
/// Setting `list-style-type:none` on the wrapping `<ol>/<ul>` wasn't
/// reliable — flutter_html's default decimal rendering kicked in despite
/// the inline style, so we'd see `1.` next to the inlined `①`. Replacing
/// the list with `<div>`s removes flutter_html's marker rendering path
/// entirely. We preserve every attribute (including `data-content` and any
/// inline `style` we'd already added in [_addSenseSpacing]) on the new
/// `<div>`s so downstream styling still applies. Glossary `<ul>`s are
/// flattened the same way so the `•` bullets disappear and each gloss
/// renders on its own line as a plain `<div>`.
///
/// Non-Jitendex `<ol>`/`<ul>`s (whose children don't carry
/// `data-content="sense"` or `"sense-group"`, and which aren't tagged as
/// `data-content="glossary"`) are left untouched.
void _flattenSenseLists(dom.Document document) {
  final senseLists = <dom.Element>{};
  final glossaryLists = <dom.Element>{};

  for (final li in document.querySelectorAll('li')) {
    final marker = li.attributes['data-content'];
    if (marker != 'sense' && marker != 'sense-group') continue;

    String? markerText;
    final declared = _readListStyleType(li);
    if (declared != null) {
      final m = _quotedListStyleRegex.firstMatch(declared);
      if (m != null) markerText = m.group(1);
    }
    _stripListStyleType(li);

    if (markerText != null && markerText.isNotEmpty) {
      final firstGlossLi = _findFirstGlossaryItem(li);
      if (firstGlossLi != null) {
        // Hanging indent. Wrap the marker in an inline-block span with an
        // explicit width so the rendered cell is exactly [_glossIndent]
        // wide, no matter the font's natural CJK-vs-ASCII metrics. Then
        // give every gloss after the first the same left padding so its
        // text lines up under the first gloss's text. Without the fixed
        // span width the marker+space cell is ~1.25em (CJK ① ≈ 1em + ASCII
        // space ≈ 0.25em) which left a ~0.25em mismatch against a 1.5em
        // padding.
        final markerSpan = dom.Element.tag('span');
        markerSpan.attributes['style'] =
            'display:inline-block;width:$_glossIndent';
        markerSpan.append(dom.Text(markerText));
        firstGlossLi.nodes.insert(0, markerSpan);

        final glossary = firstGlossLi.parent;
        if (glossary != null) {
          var seenFirst = false;
          for (final sibling in glossary.children) {
            if (sibling.localName != 'li') continue;
            if (!seenFirst) {
              seenFirst = true;
              continue;
            }
            _appendInlineStyle(sibling, 'padding-left:$_glossIndent');
          }
        }
      } else {
        li.nodes.insert(0, dom.Text('$markerText '));
      }
    }

    final parent = li.parent;
    if (parent != null &&
        (parent.localName == 'ol' || parent.localName == 'ul')) {
      senseLists.add(parent);
    }
  }

  // Glossary <ul>s render with default `•` bullets in flutter_html — and
  // the user wants the gloss list to read as plain newline-separated lines.
  // Collect them and flatten alongside the sense lists.
  for (final ul in document.querySelectorAll('ul')) {
    if (ul.attributes['data-content'] == 'glossary') {
      glossaryLists.add(ul);
    }
  }

  for (final list in senseLists) {
    _replaceListWithDivs(list);
  }
  for (final ul in glossaryLists) {
    _replaceListWithDivs(ul);
  }
}

/// Look for a direct-child `<ul data-content="glossary">` of [senseLi] and
/// return its first `<li>` child, if any. Returns null when the sense has
/// no glossary list (e.g. interjection-style "hey/oi/come on" senses where
/// the glosses sit directly under the sense container) or when the
/// glossary is empty.
dom.Element? _findFirstGlossaryItem(dom.Element senseLi) {
  for (final c in senseLi.children) {
    if (c.localName == 'ul' && c.attributes['data-content'] == 'glossary') {
      for (final li in c.children) {
        if (li.localName == 'li') return li;
      }
      return null;
    }
  }
  return null;
}

/// Replace [list] (`<ol>` or `<ul>`) with a `<div>`, and each child `<li>`
/// with a `<div>`, preserving attributes (including `data-content` and any
/// inline `style`). Non-`<li>` children (rare) are moved across as-is.
void _replaceListWithDivs(dom.Element list) {
  final newList = dom.Element.tag('div');
  newList.attributes.addAll(list.attributes);
  // Block layout — divs default to block but be explicit so any cascading
  // inline style we added (margin-bottom etc.) renders predictably.
  _appendInlineStyle(newList, 'display:block');

  // Snapshot children before we start moving them around.
  final childrenSnapshot = list.children.toList();
  for (final child in childrenSnapshot) {
    if (child.localName == 'li') {
      final newLi = dom.Element.tag('div');
      newLi.attributes.addAll(child.attributes);
      _appendInlineStyle(newLi, 'display:block');
      while (child.nodes.isNotEmpty) {
        final n = child.nodes.first;
        n.remove();
        newLi.append(n);
      }
      child.remove();
      newList.append(newLi);
    } else {
      child.remove();
      newList.append(child);
    }
  }
  list.replaceWith(newList);
}

/// Add a bottom margin to each `<li data-content="sense">` (and sense-group)
/// so consecutive senses get clear breathing room — without this every
/// numbered sense runs into the next, especially when a sense has multiple
/// callouts (Note, examples, See-also). Skips the trailing sense in each
/// list so the entry doesn't end with dead whitespace.
void _addSenseSpacing(dom.Document document) {
  for (final li in document.querySelectorAll('li')) {
    final marker = li.attributes['data-content'];
    if (marker != 'sense' && marker != 'sense-group') continue;
    final parent = li.parent;
    if (parent == null) continue;
    final siblings =
        parent.children.where((c) => c.localName == 'li').toList();
    if (siblings.last == li) continue;
    _appendInlineStyle(li, 'margin-bottom:14px');
  }
}

/// Polish inline Jitendex markers that appear inside our callout boxes.
/// flutter_html's `style` map only supports tag selectors, so attribute-based
/// targeting (`div[data-content="sense-note-label"]`) has to be done by
/// injecting inline styles on the DOM. Keep this list small and targeted.
void _styleJitendexInlineMarkers(dom.Document document) {
  for (final el in document.querySelectorAll('*')) {
    final marker = el.attributes['data-content'];
    if (marker == null) continue;
    switch (marker) {
      case 'sense-note-label':
        // Gold italic header inside the Note callout, matching Yomitan's
        // "Note" pill — the inner italic style for the note body is applied
        // via DefaultTextStyle in the extension.
        _appendInlineStyle(el, 'color:#d4a017');
        _appendInlineStyle(el, 'font-style:italic');
        _appendInlineStyle(el, 'font-size:0.85em');
        _appendInlineStyle(el, 'letter-spacing:0.3px');
        break;
      case 'sense-note-content':
        _appendInlineStyle(el, 'font-style:italic');
        break;
      case 'xref-glossary':
        // Yomitan renders the preview line slightly smaller and muted under
        // the See-also header. opacity isn't in flutter_html's whitelist, so
        // use color directly.
        _appendInlineStyle(el, 'font-size:0.9em');
        _appendInlineStyle(el, 'margin-top:2px');
        break;
      case 'reference-label':
        // "See also" prefix inside the xref box — render slightly muted +
        // small so the linked term is the visual anchor.
        _appendInlineStyle(el, 'font-size:0.9em');
        _appendInlineStyle(el, 'margin-right:4px');
        break;
      case 'example-keyword':
        _appendInlineStyle(el, 'font-weight:600');
        break;
      case 'example-sentence-a':
      case 'example-sentence-b':
        _appendInlineStyle(el, 'display:block');
        break;
      case 'examples':
        _appendInlineStyle(el, 'display:block');
        _appendInlineStyle(el, 'margin:6px 0');
        break;
    }
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

/// Get the [Directory] used as a resource directory for a certain [Dictionary].
final dictionaryResourceDirectoryProvider =
    Provider.family<Directory, int>((ref, dictionaryId) {
  final appModel = ref.watch(appProvider);

  return Directory(
      path.join(appModel.dictionaryResourceDirectory.path, '$dictionaryId'));
});

/// Renders Jitendex semantic callouts (See also, Note, Example sentence) as
/// styled Flutter widgets instead of plain `<div>` blocks. Each callout type
/// gets its own visual treatment:
///
/// - `data-content="example-sentence"` → flat dark rounded box
/// - `data-content="sense-note"` → gold left-border box (Jitendex emits its
///   own italic "Note" label as a child, styled by [_styleJitendexInlineMarkers])
/// - `data-content="xref"` → blue left-border box, whole box tappable
///   (See-also; routes to [onSearch] with the linked query so mobile users
///   get a comfortable touch target). The two-line layout — "See also <term>"
///   + a preview gloss ("① that; it") — comes for free because Jitendex
///   already emits both as children (`xref-content` + `xref-glossary`).
///
/// Inner content is rendered via a nested [Html] widget that re-uses the
/// outer font size + link colour, so `<ruby>` furigana, links, and any
/// child blocks still render correctly inside the box.
class _JitendexCalloutExtension extends HtmlExtension {
  _JitendexCalloutExtension({
    required this.onSearch,
    required this.fontSize,
    required this.textColor,
    required this.linkColor,
    required this.exampleFill,
  });

  final void Function(String) onSearch;
  final double fontSize;
  final Color textColor;
  final Color linkColor;
  final Color exampleFill;

  static const Color _noteAccent = Color(0xffd4a017); // amber/gold
  static const Color _seeAlsoAccent = Color(0xff4a90c8); // blue

  @override
  Set<String> get supportedTags => const {'div'};

  @override
  bool matches(ExtensionContext c) {
    final dc = c.element?.attributes['data-content'];
    if (dc == null) return false;
    return _exampleSentenceMarkers.contains(dc) ||
        _noteMarkers.contains(dc) ||
        _seeAlsoMarkers.contains(dc);
  }

  Widget _buildInnerHtml(dom.Element el, {Color? linkOverride}) {
    return Html(
      data: el.innerHtml,
      shrinkWrap: true,
      onAnchorTap: (url, attributes, element) {
        onSearch.call(attributes['query'] ?? element?.text ?? '');
      },
      style: {
        '*': Style(fontSize: FontSize(fontSize)),
        'body': Style(
          margin: Margins.zero,
          padding: HtmlPaddings.zero,
          color: textColor,
        ),
        'a': Style(
          color: linkOverride ?? linkColor,
          fontWeight: FontWeight.w600,
        ),
        'ul': Style(
          padding: HtmlPaddings.only(left: fontSize),
          margin: Margins.symmetric(vertical: 0, unit: Unit.px),
        ),
        'ol': Style(
          padding: HtmlPaddings.only(left: fontSize),
          margin: Margins.symmetric(vertical: 0, unit: Unit.px),
        ),
        'li': Style(padding: HtmlPaddings.zero),
      },
    );
  }

  @override
  InlineSpan build(ExtensionContext c) {
    final el = c.element!;
    final dc = el.attributes['data-content']!;

    if (_exampleSentenceMarkers.contains(dc)) {
      return WidgetSpan(
        child: JidoujishoCalloutBox(
          accent: linkColor,
          hasLeftBorder: false,
          solidFill: exampleFill,
          child: _buildInnerHtml(el),
        ),
      );
    }

    if (_noteMarkers.contains(dc)) {
      // Jitendex already emits a "Note" label inside the structured content,
      // so we don't add our own header here — that just produced "Note Note"
      // in the rendered box. The italic body styling comes from upstream.
      return WidgetSpan(
        child: JidoujishoCalloutBox(
          accent: _noteAccent,
          child: _buildInnerHtml(el),
        ),
      );
    }

    // See-also.
    final anchor = el.querySelector('a[href]');
    final query = anchor?.attributes['href']?.replaceFirst('?query=', '') ??
        anchor?.text.trim() ??
        '';
    return WidgetSpan(
      child: JidoujishoCalloutBox(
        accent: _seeAlsoAccent,
        onTap: query.isEmpty ? null : () => onSearch(query),
        child: _buildInnerHtml(el, linkOverride: _seeAlsoAccent),
      ),
    );
  }
}

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final linkColor = Theme.of(context).colorScheme.error;
    final dictionaryFontSize = ref.read(appProvider).dictionaryFontSize;
    final fontSize = FontSize(dictionaryFontSize);
    // Example-sentence callouts use a flat fill that contrasts UP from the
    // scaffold (slightly lighter on dark, slightly darker on light) so the
    // box reads as inset rather than as a border.
    final exampleFill =
        isDark ? const Color(0xff2a2a2a) : const Color(0xfff3f3f3);
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
          // Replace Jitendex semantic <div data-content="..."> blocks with
          // styled callout widgets (See also, Note, Example sentence).
          _JitendexCalloutExtension(
            onSearch: onSearch,
            fontSize: dictionaryFontSize,
            textColor: textColor,
            linkColor: linkColor,
            exampleFill: exampleFill,
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
