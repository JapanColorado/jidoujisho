import 'dart:convert';
import 'dart:io';

import 'package:async_zip/async_zip.dart';
import 'package:beautiful_soup_dart/beautiful_soup.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:isar/isar.dart';
import 'package:list_counter/list_counter.dart';
import 'package:path/path.dart' as path;
import 'package:recase/recase.dart';
import 'package:collection/collection.dart';
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/utils.dart';

/// A dictionary format for archives following the latest Yomichan bank schema.
/// Example dictionaries for this format may be downloaded from the Yomichan
/// website.
///
/// Details on the format can be found here:
/// https://github.com/FooSoft/yomichan/blob/master/ext/data/schemas/dictionary-term-bank-v3-schema.json
class YomichanFormat extends DictionaryFormat {
  /// Define a format with the given metadata that has its behaviour for
  /// import, search and display defined with af set of top-level helper methods.
  YomichanFormat._privateConstructor()
      : super(
          uniqueKey: 'yomichan',
          name: 'Yomichan Dictionary',
          icon: Icons.auto_stories_rounded,
          allowedExtensions: const ['zip'],
          isTextFormat: false,
          fileType: FileType.custom,
          prepareDirectory: prepareDirectoryYomichanFormat,
          prepareName: prepareNameYomichanFormat,
          prepareEntries: prepareEntriesYomichanFormat,
          prepareTags: prepareTagsYomichanFormat,
          preparePitches: preparePitchesYomichanFormat,
          prepareFrequencies: prepareFrequenciesYomichanFormat,
        );

  /// Get the singleton instance of this dictionary format.
  static YomichanFormat get instance => _instance;

  static final YomichanFormat _instance = YomichanFormat._privateConstructor();

  /// If true, uses the [customDefinitionWidget] instead.
  @override
  bool shouldUseCustomDefinitionWidget(String definition) {
    try {
      jsonDecode(definition);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  String getCustomDefinitionText(String meaning) {
    final node =
        StructuredContent.processContent(jsonDecode(meaning))?.toNode();
    if (node == null) {
      return '';
    }

    final document = dom.Document.html('');
    document.body?.append(node);

    // Walk every <ul>/<ol> and rewrite its <li> children with the right
    // marker. Iterating per-list (not flat over all <li>s) lets us track a
    // separate index per list, so ordered lists number correctly.
    for (final list in document.querySelectorAll('ul, ol')) {
      final css = list.attributes['style'] ?? '';
      final declared = css
          .split(';')
          .where((e) => e.contains('list-style-type'))
          .firstOrNull
          ?.split(':')
          .lastOrNull
          ?.trim();
      // Default is the user-agent default for the list type — `decimal` for
      // <ol>, `disc` for <ul>.
      final styleName = declared ?? (list.localName == 'ol' ? 'decimal' : 'disc');
      final counterStyle = CounterStyleRegistry.lookup(styleName);

      var index = 0;
      for (final li in list.children.where((c) => c.localName == 'li')) {
        final text = li.text;
        final marker = counterStyle.generateMarkerContent(index);
        li.text = '$marker $text';
        index++;
      }
    }

    // Render tables as tab-separated text rows so card export keeps tabular
    // content instead of dropping it entirely. (The previous
    // `.map((e) => e.remove())` was a no-op — `.map` is lazy in Dart.)
    for (final table in document.querySelectorAll('table')) {
      final lines = <String>[];
      for (final row in table.querySelectorAll('tr')) {
        final cells = row
            .querySelectorAll('td, th')
            .map((c) => c.text.trim())
            .toList();
        lines.add(cells.join('\t'));
      }
      table.replaceWith(dom.Text(lines.join('\n')));
    }

    final html = document.body?.innerHtml ?? '';

    return BeautifulSoup(html).getText(separator: '\n');
  }

  /// Recursively get HTML for a structured content definition.
  static String getStructuredContentHtml(dynamic content) {
    if (content is Map) {
      return getNodeHtml(
        tag: content['tag'],
        content: getStructuredContentHtml(content['content']),
        style: getStyle(
          content['style'] ?? {},
        ),
      );
    } else if (content is List) {
      return content.map(getStructuredContentHtml).join();
    }

    return content;
  }

  /// Convert style to appropriate format.
  static Map<String, String> getStyle(Map<String, dynamic> styleMap) {
    return Map<String, String>.fromEntries(
      styleMap.entries.map(
        (e) => MapEntry(
          ReCase(e.key).paramCase,
          e.value.toString(),
        ),
      ),
    );
  }

  /// Get the HTML for a certain node.
  static String getNodeHtml({
    required String content,
    String? tag,
    Map<String, String> style = const {},
  }) {
    if (tag == null) {
      return content;
    }

    dom.Element element = dom.Element.tag(tag);
    element.attributes.addAll(style);

    element.innerHtml = content;

    return element.outerHtml;
  }

  /// For [prepareEntriesYomichanFormat].
  static String? processDefinition(var definition) {
    if (definition is String) {
      final plainText = definition;
      return plainText;
    } else if (definition is Map) {
      final type = definition['type'];

      switch (type) {
        case 'text':
          final plainText = definition['text'];
          return plainText;
        case 'structured-content':
        case 'image':
          return jsonEncode(definition['content']);
      }
    }

    return null;
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> prepareDirectoryYomichanFormat(
    PrepareDirectoryParams params) async {
  int n = 0;
  extractZipArchiveSync(params.file, params.resourceDirectory,
      callback: (_, __) {
    n++;
    params.send(t.import_extract_count(n: n));
  });
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<String> prepareNameYomichanFormat(PrepareDirectoryParams params) async {
  /// Get the index, which contains the name of the dictionary contained by
  /// the archive.
  String indexFilePath = path.join(params.resourceDirectory.path, 'index.json');
  File indexFile = File(indexFilePath);
  String indexJson = indexFile.readAsStringSync();
  Map<String, dynamic> index = jsonDecode(indexJson);

  String dictionaryName = (index['title'] as String).trim();
  return dictionaryName;
}

/// One sense extracted from a Yomitan structured-content definition by
/// [_splitDefinitionBySense]. Carries the JSON-encoded definition for that
/// sense (with inline tag spans removed) plus the lifted tags pulled out of
/// those spans — these become chip rows on the entry.
class _SenseSplit {
  const _SenseSplit(this.definition, this.tags);

  final String definition;
  final List<_LiftedTag> tags;
}

/// One inline tag span lifted from a sense's body — Jitendex's
/// `<span data-content="*-info" data-code="…">label</span>` markers carry
/// POS/misc/field/dialect labels we want to show as chips.
class _LiftedTag {
  const _LiftedTag({
    required this.name,
    required this.notes,
    required this.category,
  });

  final String name;     // chip text — span's text content (e.g. "pronoun")
  final String notes;    // tooltip — span's title attr (e.g. "pronoun")
  final String category; // colour category (see DictionaryTag.color)
}

/// Map a Jitendex `data.content` marker to a [DictionaryTag.category] value
/// used for chip colouring.
String _categoryForInfoMarker(String marker) {
  if (marker.startsWith('part-of-speech')) return 'partOfSpeech';
  if (marker.startsWith('misc')) return 'frequent';
  if (marker.startsWith('field')) return 'expression';
  if (marker.startsWith('dialect')) return 'expression';
  return 'frequent';
}

/// Walk a Yomitan structured-content definition and split on the outer
/// `<ol>`/`<ul>` of senses (the shape Jitendex and other JMdict-derived
/// dictionaries use). Returns one [_SenseSplit] per top-level `<li>`.
///
/// If the definition is plain text, isn't structured-content JSON, or doesn't
/// match the sense-list shape, the original is returned unchanged as a
/// single-element list — so non-Jitendex dictionaries are unaffected.
List<_SenseSplit> _splitDefinitionBySense(String rawDefinition) {
  dynamic decoded;
  try {
    decoded = jsonDecode(rawDefinition);
  } catch (_) {
    return [_SenseSplit(rawDefinition, const [])];
  }

  // Jitendex's top-level shape is a List (e.g. [<ul sense-groups>,
  // <div attribution>]) — older shapes wrap in a single Map. Search both
  // forms recursively for a `<ol>`/`<ul>` with two or more `<li>` children
  // that we can treat as the sense list.
  final liChildren = _findSenseListChildren(decoded);

  // Drop Jitendex's bottom "JMdict | Tatoeba" attribution div from every
  // path — the dictionary chip above the entry already conveys the source.
  _stripAttributionDivs(decoded);

  if (liChildren == null) {
    // No multi-sense split: still lift inline tag spans so POS / misc /
    // field / dialect surface as chips above the entry (and stop rendering
    // as plain text concatenated into the gloss).
    final codes = _extractAndStripTagSpans(decoded);
    return [_SenseSplit(jsonEncode(decoded), codes)];
  }

  return liChildren.map((li) {
    // _extractAndStripTagSpans mutates in place: it pulls every Jitendex
    // tag-info span out of the tree (so they don't render in the body) and
    // returns their codes (so they can become chips on the entry).
    final liContent = (li as Map)['content'];
    final codes = _extractAndStripTagSpans(liContent);
    return _SenseSplit(jsonEncode(liContent), codes);
  }).toList();
}

/// Walk a Yomitan structured-content subtree and remove every
/// `<div data-content="attribution">` Map from any List children. Jitendex
/// emits this as a top-level sibling of the sense-groups `<ul>` and uses it
/// for the "JMdict | Tatoeba" source line that the user doesn't want shown
/// (the dictionary source already appears as a chip above the entry).
///
/// Same shape as [_walkAndStripTagSpans] — recurse into Maps via
/// `node['content']`, on Lists `removeWhere` the matching entries.
void _stripAttributionDivs(dynamic node) {
  if (node is List) {
    for (final child in node) {
      _stripAttributionDivs(child);
    }
    node.removeWhere((c) {
      if (c is! Map) return false;
      if (c['tag'] != 'div') return false;
      final data = c['data'];
      if (data is! Map) return false;
      return data['content'] == 'attribution';
    });
  } else if (node is Map) {
    _stripAttributionDivs(node['content']);
  }
}

/// Recursively search [node] for the outermost `<ol>`/`<ul>` whose
/// `data.content == "sense-groups"` — Jitendex's canonical marker for the
/// outer sense list. Returns the `<li>` children with that marker, or null
/// if absent (depth-bounded to avoid pathological cycles).
///
/// Restricting to the explicit marker prevents accidentally splitting on
/// the inner sub-sense `<ol>` (the ① ② ③ list) inside a single-POS entry.
List<dynamic>? _findSenseListChildren(dynamic node, [int depth = 0]) {
  if (depth > 8) return null;
  if (node is Map) {
    final tag = node['tag'];
    final content = node['content'];
    final data = node['data'];
    if ((tag == 'ol' || tag == 'ul') &&
        content is List &&
        data is Map &&
        data['content'] == 'sense-groups') {
      final lis =
          content.where((c) => c is Map && c['tag'] == 'li').toList();
      if (lis.length >= 2) return lis;
    }
    if (content != null) return _findSenseListChildren(content, depth + 1);
  } else if (node is List) {
    for (final child in node) {
      final found = _findSenseListChildren(child, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

/// Walk a Yomitan structured-content subtree and:
///  1. Collect every Jitendex tag span — `<span data-content="*-info"
///     data-code="…">label</span>` — into a list of [_LiftedTag] records
///     using the span's text content as the chip name and its `title`
///     attribute as the tooltip.
///  2. Remove those spans from the tree in place (so they don't double up
///     as plain text in the rendered entry body once they're chips).
///
/// Returns the lifted tags in document order with duplicates (by name)
/// removed — preserves the order Jitendex emits them so chips render the
/// same way every time.
List<_LiftedTag> _extractAndStripTagSpans(dynamic node) {
  final tags = <_LiftedTag>[];
  final seen = <String>{};
  _walkAndStripTagSpans(node, tags, seen);
  return tags;
}

void _walkAndStripTagSpans(
  dynamic node,
  List<_LiftedTag> tags,
  Set<String> seen,
) {
  if (node is List) {
    for (final child in node) {
      _walkAndStripTagSpans(child, tags, seen);
    }
    node.removeWhere((c) {
      if (c is! Map) return false;
      if (c['tag'] != 'span') return false;
      final data = c['data'];
      if (data is! Map) return false;
      final marker = data['content'];
      if (marker is! String || !marker.endsWith('-info')) return false;

      // Span's text content becomes the chip name. It's typically a plain
      // string ("pronoun", "kana"); guard against richer shapes by falling
      // back to the data.code as a last resort.
      final spanContent = c['content'];
      String? name;
      if (spanContent is String && spanContent.trim().isNotEmpty) {
        name = spanContent.trim();
      } else {
        final code = data['code'];
        if (code is String && code.isNotEmpty) name = code;
      }
      if (name == null) return true; // remove the span anyway

      if (!seen.add(name)) return true; // dedupe but still strip

      final title = c['title'];
      tags.add(_LiftedTag(
        name: name,
        notes: title is String && title.isNotEmpty ? title : name,
        category: _categoryForInfoMarker(marker),
      ));
      return true;
    });
  } else if (node is Map) {
    _walkAndStripTagSpans(node['content'], tags, seen);
  }
}

/// Batches Isar writes during a Yomichan import so the per-row index-update
/// cost of [IsarCollection.putSync] is amortised across thousands of rows.
///
/// Three things make this much faster than the per-row version it replaced:
///
///  1. **Within-batch heading cache.** A `Map<int, DictionaryHeading>` deduped
///     within one flush window avoids the per-entry
///     `isar.dictionaryHeadings.getSync` round-trip when the same heading
///     shows up multiple times in a single batch (Jitendex multi-sense splits,
///     plus the merged pitch+freq pass touching the same headings prepareEntries
///     just wrote). It is **cleared on every flush** — keeping it for the full
///     import meant a 200k-row import pinned ~50 MB of Dart objects in old-gen
///     and produced lengthening GC pauses around the 100k mark.
///  2. **`putAllSync` per flush.** Isar batches index updates within a single
///     cursor session, which is dramatically faster than N `putSync` calls
///     for index-heavy collections — `DictionaryHeading` carries three
///     indexes (case-insensitive `term`, case-insensitive `reading`, and
///     `termLength`) so this is where the largest win comes from.
///  3. **No redundant backlink maintenance.** `heading.entries`,
///     `heading.pitches`, and `heading.frequencies` are `@Backlink` IsarLinks
///     — Isar derives them from the forward link Isar already persists when
///     `putAllSync(entries)` saves `entry.heading.value`. The previous code
///     called `heading.entries.add(entry); isar.dictionaryHeadings.putSync(heading)`
///     after every entry, which paid for ~100k unnecessary heading writes.
///
/// The flush threshold is a fixed 10000 pending "leaf" rows (entries + pitches
/// + frequencies). An earlier version had adaptive shrink-on-failure logic,
/// but it interacted poorly with transient errors and was removed — if a
/// batch is too big for the device, the user will see an OOM error rather
/// than silent slowdown.
class _ImportBatcher {
  /// `tag_bank`-declared tag rows for this dictionary, keyed by
  /// `DictionaryTag.hash`. Small (typically <500 entries) and lives for the
  /// full import — populated by [prepareTagsYomichanFormat] before
  /// `prepareEntries` runs, then read-only.
  final Map<int, DictionaryTag> _tagCache = {};

  /// Headings touched in the current batch only. Cleared on every flush so
  /// memory doesn't accumulate across a 100k+ entry import. A cache miss in a
  /// later batch falls through to [lookupOrCreateHeading]'s `getSync`.
  final Map<int, DictionaryHeading> _hotHeadings = {};

  // Pending sets for the next flush. Headings/tags are deduped by id; the
  // leaf collections (entries, pitches, frequencies) keep insertion order so
  // progress messages stay monotonic.
  final Set<int> _pendingHeadingIds = {};
  final Set<int> _pendingTagIds = {};
  final List<DictionaryEntry> _pendingEntries = [];
  final List<DictionaryPitch> _pendingPitches = [];
  final List<DictionaryFrequency> _pendingFrequencies = [];

  static const int _flushThreshold = 10000;

  /// Look up an existing in-memory heading by id, or fall through to Isar (in
  /// case a prior batch's flush wrote it, or another dictionary already
  /// created it), or construct a new one. Always added to the per-batch hot
  /// cache and the pending-heading set so the next flush writes it.
  DictionaryHeading lookupOrCreateHeading(
    Isar isar, {
    required String term,
    required String reading,
  }) {
    final id = DictionaryHeading.hash(term: term, reading: reading);
    final cached = _hotHeadings[id];
    if (cached != null) return cached;

    final stored = isar.dictionaryHeadings.getSync(id);
    final heading = stored ?? DictionaryHeading(term: term, reading: reading);
    _hotHeadings[id] = heading;
    _pendingHeadingIds.add(id);
    return heading;
  }

  /// Register a tag for writing. First-write wins on duplicate hash ids so
  /// the predeclared `tag_bank` definition isn't overwritten by a later
  /// synthesized inline tag with the same name.
  void addTag(DictionaryTag tag) {
    final id = tag.isarId;
    if (_tagCache.containsKey(id)) return;
    _tagCache[id] = tag;
    _pendingTagIds.add(id);
  }

  /// Resolve a tag by its computed id. Returns null if no `tag_bank`/inline
  /// tag with this id has been registered — the caller should skip linking
  /// it (preserving the existing behaviour of [Iterable.whereType] over
  /// `getAllSync`).
  DictionaryTag? lookupTag(int id) => _tagCache[id];

  void addEntry(DictionaryEntry entry) => _pendingEntries.add(entry);
  void addPitch(DictionaryPitch pitch) => _pendingPitches.add(pitch);
  void addFrequency(DictionaryFrequency frequency) =>
      _pendingFrequencies.add(frequency);

  /// Whether the leaf-row pending count has reached the flush threshold.
  bool get shouldFlush =>
      _pendingEntries.length +
          _pendingPitches.length +
          _pendingFrequencies.length >=
      _flushThreshold;

  void maybeFlush(Isar isar) {
    if (shouldFlush) flush(isar);
  }

  /// Drain all pending writes into one Isar transaction, then clear the
  /// per-batch heading cache. Errors propagate to the caller's catch block,
  /// which rolls back the partial dictionary via `deleteDictionaryHelper`.
  void flush(Isar isar) {
    if (_pendingTagIds.isEmpty &&
        _pendingHeadingIds.isEmpty &&
        _pendingEntries.isEmpty &&
        _pendingPitches.isEmpty &&
        _pendingFrequencies.isEmpty) {
      return;
    }

    final tags = _pendingTagIds.map((id) => _tagCache[id]!).toList();
    final headings = _pendingHeadingIds.map((id) => _hotHeadings[id]!).toList();
    final entries = _pendingEntries.toList();
    final pitches = _pendingPitches.toList();
    final frequencies = _pendingFrequencies.toList();

    _pendingTagIds.clear();
    _pendingHeadingIds.clear();
    _pendingEntries.clear();
    _pendingPitches.clear();
    _pendingFrequencies.clear();

    // Order matters when consumers immediately query the half-flushed
    // database: tags must exist before entries link to them by id;
    // headings must exist before entries/pitches/frequencies attach their
    // forward link. Within one transaction Isar doesn't enforce referential
    // integrity, but writing in dependency order keeps on-disk state
    // queryable from any point after this flush returns.
    isar.writeTxnSync(() {
      if (tags.isNotEmpty) isar.dictionaryTags.putAllSync(tags);
      if (headings.isNotEmpty) isar.dictionaryHeadings.putAllSync(headings);
      if (entries.isNotEmpty) isar.dictionaryEntrys.putAllSync(entries);
      if (pitches.isNotEmpty) isar.dictionaryPitchs.putAllSync(pitches);
      if (frequencies.isNotEmpty) {
        isar.dictionaryFrequencys.putAllSync(frequencies);
      }
    });

    // Free the in-memory heading objects (and the DictionaryEntry/Pitch/
    // Frequency objects they transitively pin via IsarLinks) so old-gen GC
    // pressure stays bounded by one batch's worth of rows rather than the
    // whole import.
    _hotHeadings.clear();
  }
}

/// Top-level state for the active Yomichan import. The import isolate
/// processes one dictionary at a time, so a single nullable field is enough
/// — but it MUST be reset by [finalizeYomichanImport] (or the catch block
/// in `depositDictionaryDataHelper`) so a subsequent import on the same
/// isolate doesn't see stale caches. The four `prepare*` functions below
/// share this batcher so caches survive across phases.
_ImportBatcher? _activeBatcher;

_ImportBatcher _batcher() => _activeBatcher ??= _ImportBatcher();

/// Flush any remaining pending writes and clear the active batcher. Called
/// from `depositDictionaryDataHelper` after all four prepare* functions
/// have run.
void finalizeYomichanImport({required Isar isar}) {
  final batcher = _activeBatcher;
  if (batcher == null) return;
  batcher.flush(isar);
  _activeBatcher = null;
}

/// Discard the active batcher without flushing. Called from the error path
/// in `depositDictionaryDataHelper` so a retried import starts clean.
void abandonYomichanImport() {
  _activeBatcher = null;
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
void prepareEntriesYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) {
  final batcher = _batcher();
  final List<FileSystemEntity> entities = params.resourceDirectory.listSync();
  final Iterable<File> files = entities.whereType<File>();
  final int dictionaryId = params.dictionary.id;

  int n = 0;
  int total = 0;

  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('term_bank') || filename.startsWith('kanji_bank')) {
      String json = file.readAsStringSync();
      List<dynamic> items = jsonDecode(json);
      total += items.length;

      params.send(t.import_found_entry(count: total));
    }
  }

  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('term_bank')) {
      List<dynamic> items = jsonDecode(file.readAsStringSync());

      for (List<dynamic> item in items) {
        final String term = item[0];
        final String reading = item[1];
        final String? spaceSeparatedDefinitionTags = item[2];
        // final String ruleIdentifier = item[3];
        final num rawPopularity = item[4];
        final List<dynamic> rawDefinitions = item[5];
        // final int sequenceNumber = item[6];
        final String spaceSeparatedTermTags = item[7];

        final double popularity = rawPopularity.toDouble();
        final List<String> entryTagNames =
            spaceSeparatedDefinitionTags?.split(' ') ?? const [];
        final List<String> headingTagNames = spaceSeparatedTermTags.split(' ');

        // Split each raw definition on its top-level <ol>/<ul> of senses
        // (Jitendex shape). Plain-text and single-sense definitions pass
        // through unchanged as a single split.
        final List<_SenseSplit> splits = rawDefinitions
            .map(YomichanFormat.processDefinition)
            .whereType<String>()
            .expand(_splitDefinitionBySense)
            .toList();
        if (splits.isEmpty) continue;

        final DictionaryHeading heading = batcher.lookupOrCreateHeading(
          isar,
          term: term,
          reading: reading,
        );

        // Heading tags come from the term-level `spaceSeparatedTermTags`
        // (declared in `tag_bank` by Yomichan convention). Resolve them
        // against the batcher's in-memory tag cache populated by
        // `prepareTagsYomichanFormat`. The heading is already marked dirty
        // by lookupOrCreateHeading, so no further bookkeeping is needed —
        // Isar's IsarLinks tracks adds incrementally and re-add is a no-op.
        for (final tagName in headingTagNames) {
          final tag = batcher.lookupTag(
              DictionaryTag.hash(dictionaryId: dictionaryId, name: tagName));
          if (tag != null) heading.tags.add(tag);
        }

        // Create one DictionaryEntry per split. Each entry inherits the
        // term-level entry tags plus every tag lifted out of the sense's
        // inline `<span data-content="*-info">` markers (POS, misc, field,
        // dialect — see `_extractAndStripTagSpans`). Jitendex's tag_bank
        // doesn't predeclare these, so we synthesize the DictionaryTag rows
        // on the fly here — the batcher dedups by `(dictionaryId, name)`
        // hash so duplicates across senses collapse into one row.
        for (final split in splits) {
          for (final liftedTag in split.tags) {
            batcher.addTag(DictionaryTag(
              dictionaryId: dictionaryId,
              name: liftedTag.name,
              category: liftedTag.category,
              sortingOrder: 0,
              notes: liftedTag.notes,
              popularity: 0,
            ));
          }

          final List<String> mergedTagNames = [
            ...entryTagNames,
            ...split.tags.map((t) => t.name),
          ];

          final entry = DictionaryEntry(
            definitions: [split.definition],
            popularity: popularity,
            entryTagNames: mergedTagNames,
            headingTagNames: headingTagNames,
          );

          for (final tagName in mergedTagNames) {
            final tag = batcher.lookupTag(
                DictionaryTag.hash(dictionaryId: dictionaryId, name: tagName));
            if (tag != null) entry.tags.add(tag);
          }
          entry.heading.value = heading;
          entry.dictionary.value = params.dictionary;
          batcher.addEntry(entry);
        }

        n++;
        // Throttle progress messages — each send crosses the isolate
        // boundary and allocates a localised string, which adds measurable
        // overhead at 200k+ items. Once every 250 keeps the UI responsive
        // without burning isolate-send time on writes that complete in <1ms.
        if (n % 250 == 0 || n == total) {
          params.send(t.import_write_entry(count: n, total: total));
        }
        batcher.maybeFlush(isar);
      }
    } else if (filename.startsWith('kanji_bank')) {
      List<dynamic> items = jsonDecode(file.readAsStringSync());

      for (List<dynamic> item in items) {
        String term = item[0] as String;
        List<String> onyomis = (item[1] as String).split(' ');
        List<String> kunyomis = (item[2] as String).split(' ');
        List<String> headingTagNames = (item[3] as String).split(' ');
        List<String> meanings = List<String>.from(item[4]);

        StringBuffer buffer = StringBuffer();
        if (onyomis.join().trim().isNotEmpty) {
          buffer.write('音読み\n');
          for (String onyomi in onyomis) {
            buffer.write('  • $onyomi\n');
          }
          buffer.write('\n');
        }
        if (kunyomis.join().trim().isNotEmpty) {
          buffer.write('訓読み\n');
          for (String kun in kunyomis) {
            buffer.write('  • $kun\n');
          }
          buffer.write('\n');
        }
        if (meanings.isNotEmpty) {
          buffer.write('意味\n');
          for (String meaning in meanings) {
            buffer.write('  • $meaning\n');
          }
          buffer.write('\n');
        }

        String definition = buffer.toString().trim();
        if (definition.isEmpty) continue;

        final entry = DictionaryEntry(
          definitions: [definition],
          popularity: 0,
          headingTagNames: headingTagNames,
        );

        final DictionaryHeading heading = batcher.lookupOrCreateHeading(
          isar,
          term: term,
          reading: '',
        );

        for (final tagName in headingTagNames) {
          final tag = batcher.lookupTag(
              DictionaryTag.hash(dictionaryId: dictionaryId, name: tagName));
          if (tag != null) heading.tags.add(tag);
        }

        entry.heading.value = heading;
        entry.dictionary.value = params.dictionary;
        batcher.addEntry(entry);

        n++;
        if (n % 250 == 0 || n == total) {
          params.send(t.import_write_entry(count: n, total: total));
        }
        batcher.maybeFlush(isar);
      }
    }
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
///
/// Pushes every `tag_bank_*.json` tag into the batcher and flushes at the
/// end of the phase, so subsequent `prepareEntries` calls can resolve
/// heading/entry tag references against an in-memory cache (and a fully
/// populated Isar `dictionaryTags` collection) without any per-entry
/// `getSync` round-trips.
void prepareTagsYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) {
  final batcher = _batcher();
  final List<FileSystemEntity> entities = params.resourceDirectory.listSync();
  final Iterable<File> files = entities.whereType<File>();

  int n = 0;
  int count = 0;

  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('tag_bank')) {
      String json = file.readAsStringSync();
      List<dynamic> items = jsonDecode(json);
      count += items.length;

      params.send(t.import_found_tag(count: count));
    }
  }

  for (File file in files) {
    String filename = path.basename(file.path);
    if (!filename.startsWith('tag_bank')) continue;

    String json = file.readAsStringSync();
    List<dynamic> items = jsonDecode(json);

    for (List<dynamic> item in items) {
      String name = item[0] as String;
      String category = item[1] as String;
      int sortingOrder = item[2] as int;
      String notes = item[3] as String;
      double popularity = (item[4] as num).toDouble();

      batcher.addTag(DictionaryTag(
        dictionaryId: params.dictionary.id,
        name: name,
        category: category,
        sortingOrder: sortingOrder,
        notes: notes,
        popularity: popularity,
      ));

      n++;
      params.send(t.import_write_tag(count: n, total: count));
    }
  }

  // Materialise the tag cache to disk so `prepareEntries`-time link
  // resolution sees the canonical tag_bank rows (the batcher's
  // first-write-wins logic also means the in-memory cache already has
  // them; the flush is mostly to bound transaction size).
  batcher.flush(isar);
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
///
/// Reads each `term_meta_bank_*.json` file **once** and dispatches by `type`
/// — both pitch (`type == 'pitch'`) and frequency (`type == 'freq'`)
/// entries are processed here. The companion `prepareFrequenciesYomichanFormat`
/// is a no-op (kept for API parity with the other formats and the chisa-era
/// abstract base). Doing both kinds in one pass halves the JSON parse cost
/// for dictionaries with large term-meta files (e.g. accent dictionaries +
/// frequency lists merged into one archive).
void preparePitchesYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) {
  final batcher = _batcher();
  final List<FileSystemEntity> entities = params.resourceDirectory.listSync();
  final Iterable<File> files = entities.whereType<File>();

  int pitchTotal = 0;
  int freqTotal = 0;
  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('term_meta_bank')) {
      List<dynamic> items = jsonDecode(file.readAsStringSync());
      pitchTotal += items.length;
      freqTotal += items.length;
      params.send(t.import_found_pitch(count: pitchTotal));
    }
  }

  int pitchN = 0;
  int freqN = 0;
  for (File file in files) {
    String filename = path.basename(file.path);
    if (!filename.startsWith('term_meta_bank')) continue;

    List<dynamic> items = jsonDecode(file.readAsStringSync());

    for (List<dynamic> item in items) {
      final String term = item[0] as String;
      final String type = item[1] as String;

      if (type == 'pitch') {
        final Map<String, dynamic> data = Map<String, dynamic>.from(item[2]);
        final String reading = data['reading'] ?? '';
        final DictionaryHeading heading = batcher.lookupOrCreateHeading(
          isar,
          term: term,
          reading: reading,
        );

        final List<Map<String, dynamic>> distinctPitchJsons =
            List<Map<String, dynamic>>.from(data['pitches']);
        for (final distinctPitch in distinctPitchJsons) {
          final int downstep = distinctPitch['position'];
          final pitch = DictionaryPitch(downstep: downstep);
          pitch.dictionary.value = params.dictionary;
          pitch.heading.value = heading;
          batcher.addPitch(pitch);
        }

        pitchN++;
        if (pitchN % 250 == 0 || pitchN == pitchTotal) {
          params.send(t.import_write_pitch(count: pitchN, total: pitchTotal));
        }
        batcher.maybeFlush(isar);
      } else if (type == 'freq') {
        final _FreqShape? parsed = _parseFreqItem(term, item[2]);
        if (parsed == null) continue;

        final DictionaryHeading heading = batcher.lookupOrCreateHeading(
          isar,
          term: parsed.term,
          reading: parsed.reading,
        );

        final frequency = DictionaryFrequency(
          displayValue: parsed.displayValue,
          value: parsed.value,
        );
        frequency.dictionary.value = params.dictionary;
        frequency.heading.value = heading;
        batcher.addFrequency(frequency);

        freqN++;
        if (freqN % 250 == 0 || freqN == freqTotal) {
          params.send(t.import_write_frequency(count: freqN, total: freqTotal));
        }
        batcher.maybeFlush(isar);
      }
    }
  }
}

/// No-op for Yomichan: frequency rows are imported alongside pitches in
/// [preparePitchesYomichanFormat] so each `term_meta_bank_*.json` file is
/// parsed exactly once.
void prepareFrequenciesYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) {
  // Intentionally empty — see [preparePitchesYomichanFormat].
}

/// Normalised view of one `term_meta_bank` `type == 'freq'` row. The raw
/// schema is loose (number, int, or one of several map shapes), so this
/// extracts the term/reading/value/displayValue into one shape callers can
/// consume uniformly.
class _FreqShape {
  const _FreqShape({
    required this.term,
    required this.reading,
    required this.value,
    required this.displayValue,
  });

  final String term;
  final String reading;
  final double value;
  final String displayValue;
}

_FreqShape? _parseFreqItem(String term, dynamic raw) {
  if (raw is double) {
    final displayValue =
        (raw % 1 == 0) ? raw.toInt().toString() : raw.toString();
    return _FreqShape(
      term: term,
      reading: '',
      value: raw,
      displayValue: displayValue,
    );
  }

  if (raw is int) {
    return _FreqShape(
      term: term,
      reading: '',
      value: raw.toDouble(),
      displayValue: raw.toString(),
    );
  }

  if (raw is Map) {
    final data = Map<String, dynamic>.from(raw);
    final reading = data['reading'] ?? '';

    if (data['frequency'] is Map) {
      final freqMap = Map<String, dynamic>.from(data['frequency']);
      final num number = freqMap['value'] ?? 0;
      return _FreqShape(
        term: term,
        reading: reading,
        value: number.toDouble(),
        displayValue: freqMap['displayValue'] ?? '',
      );
    }

    if (data['displayValue'] != null) {
      final num number = data['value'] ?? 0;
      return _FreqShape(
        term: term,
        reading: reading,
        value: number.toDouble(),
        displayValue: data['displayValue'],
      );
    }

    if (data['value'] != null) {
      final num number = data['value'] ?? 0;
      return _FreqShape(
        term: term,
        reading: reading,
        value: number.toDouble(),
        displayValue: number.toInt().toString(),
      );
    }

    if (data['frequency'] is num) {
      final num frequencyValue = data['frequency'];
      final displayValue = (frequencyValue % 1 == 0)
          ? frequencyValue.toInt().toString()
          : frequencyValue.toDouble().toString();
      return _FreqShape(
        term: term,
        reading: reading,
        value: frequencyValue.toDouble(),
        displayValue: displayValue,
      );
    }

    return null;
  }

  return _FreqShape(
    term: term,
    reading: '',
    value: 0,
    displayValue: raw.toString(),
  );
}
