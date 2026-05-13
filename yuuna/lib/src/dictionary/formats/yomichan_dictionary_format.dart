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

/// Top-level function for use in compute. See [DictionaryFormat] for details.
void prepareEntriesYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) {
  final List<FileSystemEntity> entities = params.resourceDirectory.listSync();
  final Iterable<File> files = entities.whereType<File>();

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

        double popularity = rawPopularity.toDouble();
        List<String> entryTagNames =
            spaceSeparatedDefinitionTags?.split(' ') ?? [];
        List<String> headingTagNames = spaceSeparatedTermTags.split(' ');

        // Split each raw definition on its top-level <ol>/<ul> of senses
        // (Jitendex shape). Plain-text and single-sense definitions pass
        // through unchanged as a single split.
        final List<_SenseSplit> splits = rawDefinitions
            .map(YomichanFormat.processDefinition)
            .whereType<String>()
            .expand(_splitDefinitionBySense)
            .toList();
        if (splits.isEmpty) continue;

        int headingId = DictionaryHeading.hash(
          term: term,
          reading: reading,
        );

        DictionaryHeading heading =
            isar.dictionaryHeadings.getSync(headingId) ??
                DictionaryHeading(term: term, reading: reading);

        // Heading tags are shared across all senses for this term/reading,
        // so look them up once outside the per-split loop.
        List<int> headingTagHashes = headingTagNames.map((name) {
          int dictionaryId = params.dictionary.id;
          return DictionaryTag.hash(dictionaryId: dictionaryId, name: name);
        }).toList();
        List<DictionaryTag> headingTags = isar.dictionaryTags
            .getAllSync(headingTagHashes)
            .whereType<DictionaryTag>()
            .toList();
        heading.tags.addAll(headingTags);

        // Create one DictionaryEntry per split. Each entry inherits the
        // term-level entry tags plus every tag lifted out of the sense's
        // inline `<span data-content="*-info">` markers (POS, misc, field,
        // dialect — see `_extractAndStripTagSpans`). Jitendex's tag_bank
        // doesn't predeclare these (it ships only 8 form-related tags), so
        // we synthesize the DictionaryTag rows on the fly here — `putSync`
        // is keyed by `(dictionaryId, name)` so duplicates across senses
        // collapse into one row.
        for (final split in splits) {
          for (final t in split.tags) {
            isar.dictionaryTags.putSync(DictionaryTag(
              dictionaryId: params.dictionary.id,
              name: t.name,
              category: t.category,
              sortingOrder: 0,
              notes: t.notes,
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

          List<int> entryTagHashes = mergedTagNames.map((name) {
            int dictionaryId = params.dictionary.id;
            return DictionaryTag.hash(dictionaryId: dictionaryId, name: name);
          }).toList();

          List<DictionaryTag> entryTags = isar.dictionaryTags
              .getAllSync(entryTagHashes)
              .whereType<DictionaryTag>()
              .toList();

          entry.tags.addAll(entryTags);
          entry.heading.value = heading;
          entry.dictionary.value = params.dictionary;
          isar.dictionaryEntrys.putSync(entry);

          heading.entries.add(entry);
        }

        isar.dictionaryHeadings.putSync(heading);

        n++;
        params.send(t.import_write_entry(
          count: n,
          total: total,
        ));
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

        if (definition.isNotEmpty) {
          int headingId = DictionaryHeading.hash(term: term, reading: '');

          final entry = DictionaryEntry(
            definitions: [definition],
            popularity: 0,
            headingTagNames: headingTagNames,
          );

          DictionaryHeading heading =
              isar.dictionaryHeadings.getSync(headingId) ??
                  DictionaryHeading(term: term);

          entry.heading.value = heading;
          entry.dictionary.value = params.dictionary;
          List<int> headingTagHashes = headingTagNames.map((name) {
            int dictionaryId = params.dictionary.id;
            return DictionaryTag.hash(dictionaryId: dictionaryId, name: name);
          }).toList();

          List<DictionaryTag> headingTags = isar.dictionaryTags
              .getAllSync(headingTagHashes)
              .whereType<DictionaryTag>()
              .toList();

          isar.dictionaryEntrys.putSync(entry);

          heading.entries.add(entry);
          heading.tags.addAll(headingTags);
          isar.dictionaryHeadings.putSync(heading);

          n++;
          params.send(t.import_write_entry(
            count: n,
            total: total,
          ));
        }
      }
    }
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> prepareTagsYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) async {
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
    if (!filename.startsWith('tag_bank')) {
      continue;
    }

    String json = file.readAsStringSync();
    List<dynamic> items = jsonDecode(json);

    for (List<dynamic> item in items) {
      String name = item[0] as String;
      String category = item[1] as String;
      int sortingOrder = item[2] as int;
      String notes = item[3] as String;
      double popularity = (item[4] as num).toDouble();

      DictionaryTag tag = DictionaryTag(
        dictionaryId: params.dictionary.id,
        name: name,
        category: category,
        sortingOrder: sortingOrder,
        notes: notes,
        popularity: popularity,
      );

      n++;
      isar.dictionaryTags.putSync(tag);
      params.send(t.import_write_tag(
        count: n,
        total: count,
      ));
    }
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> preparePitchesYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) async {
  final List<FileSystemEntity> entities = params.resourceDirectory.listSync();
  final Iterable<File> files = entities.whereType<File>();

  int n = 0;
  int count = 0;

  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('term_meta_bank')) {
      String json = file.readAsStringSync();
      List<dynamic> items = jsonDecode(json);
      count += items.length;

      params.send(t.import_found_pitch(count: count));
    }
  }

  for (File file in files) {
    String filename = path.basename(file.path);
    if (!filename.startsWith('term_meta_bank')) {
      continue;
    }

    String json = file.readAsStringSync();
    List<dynamic> items = jsonDecode(json);

    for (List<dynamic> item in items) {
      String term = item[0] as String;
      String type = item[1] as String;

      if (type == 'pitch') {
        Map<String, dynamic> data = Map<String, dynamic>.from(item[2]);
        String reading = data['reading'] ?? '';
        int headingId = DictionaryHeading.hash(term: term, reading: reading);
        DictionaryHeading heading =
            isar.dictionaryHeadings.getSync(headingId) ??
                DictionaryHeading(term: term);

        List<Map<String, dynamic>> distinctPitchJsons =
            List<Map<String, dynamic>>.from(data['pitches']);
        for (Map<String, dynamic> distinctPitch in distinctPitchJsons) {
          int downstep = distinctPitch['position'];
          DictionaryPitch pitch = DictionaryPitch(downstep: downstep);

          pitch.dictionary.value = params.dictionary;
          isar.dictionaryPitchs.putSync(pitch);
          heading.pitches.add(pitch);
        }

        isar.dictionaryHeadings.putSync(heading);
      } else {
        continue;
      }
    }

    params.send(t.import_write_pitch(count: n, total: count));
  }
}

/// Top-level function for use in compute. See [DictionaryFormat] for details.
Future<void> prepareFrequenciesYomichanFormat({
  required PrepareDictionaryParams params,
  required Isar isar,
}) async {
  final List<FileSystemEntity> entities = params.resourceDirectory.listSync();
  final Iterable<File> files = entities.whereType<File>();

  int n = 0;
  int count = 0;

  for (File file in files) {
    String filename = path.basename(file.path);
    if (filename.startsWith('term_meta_bank')) {
      String json = file.readAsStringSync();
      List<dynamic> items = jsonDecode(json);
      count += items.length;

      params.send(t.import_found_frequency(count: count));
    }
  }

  for (File file in files) {
    String filename = path.basename(file.path);
    if (!filename.startsWith('term_meta_bank')) {
      continue;
    }

    String json = file.readAsStringSync();
    List<dynamic> items = jsonDecode(json);

    for (List<dynamic> item in items) {
      String term = item[0] as String;
      String type = item[1] as String;

      if (type == 'freq') {
        int? headingId;
        late double value;
        late String? displayValue;

        if (item[2] is double) {
          double number = item[2] as double;

          headingId = DictionaryHeading.hash(term: term, reading: '');
          value = number;
          displayValue =
              (number % 1 == 0) ? number.toInt().toString() : number.toString();
        } else if (item[2] is int) {
          int number = item[2] as int;
          headingId = DictionaryHeading.hash(term: term, reading: '');
          value = number.toDouble();
          displayValue = number.toString();
        } else if (item[2] is Map) {
          Map<String, dynamic> data = Map<String, dynamic>.from(item[2]);

          if (data['reading'] != null && data['frequency'] is Map) {
            Map<String, dynamic> frequencyData =
                Map<String, dynamic>.from(data['frequency']);

            String reading = data['reading'] ?? '';
            headingId = DictionaryHeading.hash(term: term, reading: reading);

            num number = frequencyData['value'] ?? 0;

            value = number.toDouble();
            displayValue = frequencyData['displayValue'];
          } else if (data['displayValue'] != null) {
            String reading = data['reading'] ?? '';
            headingId = DictionaryHeading.hash(term: term, reading: reading);

            num number = data['value'] ?? 0;

            value = number.toDouble();
            displayValue = data['displayValue'];
          } else if (data['value'] != null) {
            String reading = data['reading'] ?? '';
            headingId = DictionaryHeading.hash(term: term, reading: reading);

            num number = data['value'] ?? 0;

            value = number.toDouble();
            displayValue = number.toInt().toString();
          } else if (data['frequency'] is num) {
            num frequencyValue = data['frequency'];
            String reading = data['reading'] ?? '';
            headingId = DictionaryHeading.hash(term: term, reading: reading);

            value = frequencyValue.toDouble();
            displayValue = (frequencyValue % 1 == 0)
                ? frequencyValue.toInt().toString()
                : frequencyValue.toDouble().toString();
          }
        } else {
          headingId = DictionaryHeading.hash(term: term, reading: '');

          value = 0;
          displayValue = item[2].toString();
        }

        if (headingId != null) {
          DictionaryHeading heading =
              isar.dictionaryHeadings.getSync(headingId) ??
                  DictionaryHeading(term: term);

          final frequency = DictionaryFrequency(
            displayValue: displayValue ?? '',
            value: value,
          );

          n++;
          frequency.dictionary.value = params.dictionary;
          frequency.heading.value = heading;
          isar.dictionaryFrequencys.putSync(frequency);
          heading.frequencies.add(frequency);

          params.send(t.import_write_frequency(count: n, total: count));
        }
      } else {
        continue;
      }
    }
  }
}
