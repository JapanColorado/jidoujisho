import 'package:yuuna/dictionary.dart';
import 'package:isar/isar.dart';

part 'dictionary_entry.g.dart';

/// A database entity that represents single or multiple dictionary definitions,
/// which can be in text, media or in a custom format.
///
/// A dictionary value belongs to a certain imported dictionary. There may be
/// multiple distinct values belonging to a single key.
@Collection()
class DictionaryEntry {
  /// A standard dictionary entry would only contain text content, but may
  /// also be represented with image or audio, or in a custom format.
  DictionaryEntry({
    required this.definitions,
    required this.popularity,
    this.headingTagNames = const [],
    this.entryTagNames = const [],
    this.imagePaths,
    this.audioPaths,
    this.extra,
    this.id,
  });

  /// Identifier for database purposes.
  Id? id;

  /// This field is used for definitions that can be represented in text form,
  /// which will probably make up the majority of use cases.
  final List<String> definitions;

  /// Name of tags that add detail to and describe the heading this entry
  /// belongs to. This entity is non-null only during the import process. Use
  /// [tags] from the [heading] instead.
  @ignore
  final List<String> headingTagNames;

  /// Name of tags that add detail to and describe this entry. This entity is
  /// non-null only during the import process. Use [tags] instead.
  @ignore
  final List<String> entryTagNames;

  /// An optional value that if non-null, contains a path that will point to
  /// an image resource. The resource contained in the path is deleted if it
  /// exists in the file system.
  final List<String>? imagePaths;

  /// An optional value that if non-null, contains a path that will point to
  /// audio resources. All paths in this will all be deleted if it
  /// exists in the file system.
  final List<String>? audioPaths;

  /// An optional value that may be used to store structured content or
  /// metadata that cannot be represented in any other parameters.
  final String? extra;

  /// A value that can be used to sort entries when performing a database
  /// search. Lower negative values mean rarer, and higher positive values are
  /// more common.
  @Index()
  final double popularity;

  /// Returns all definitions bullet pointed if multiple, and returns the
  /// single definition if otherwise.
  String get compactDefinitions {
    if (definitions.length > 1) {
      return definitions
          .map((definition) => '• ${definition.trim()}')
          .join('\n');
    }

    return definitions.join().trim();
  }

  /// Each dictionary entry belongs to a certain heading.
  final IsarLink<DictionaryHeading> heading = IsarLink<DictionaryHeading>();

  /// Each dictionary entry belongs to a dictionary.
  final IsarLink<Dictionary> dictionary = IsarLink<Dictionary>();

  /// Each dictionary entry may have a set of tags.
  final IsarLinks<DictionaryTag> tags = IsarLinks<DictionaryTag>();

  /// Display/export order for a heading's entries: by dictionary order,
  /// then by popularity (Jitendex gives priority entries a higher score),
  /// then by id. Ids are assigned in import order, which keeps the senses
  /// split from one Jitendex entry in their original ①②③ order; Dart's
  /// [List.sort] is not stable for longer lists, so without it equal keys
  /// could be reordered. [orderByDictionaryName] maps dictionary names to
  /// [Dictionary.order]; unknown names sort first.
  static int compareForDisplay(
    DictionaryEntry a,
    DictionaryEntry b,
    Map<String, int> orderByDictionaryName,
  ) {
    final int orderA = orderByDictionaryName[a.dictionary.value?.name] ?? 0;
    final int orderB = orderByDictionaryName[b.dictionary.value?.name] ?? 0;
    final int byDictionary = orderA.compareTo(orderB);
    if (byDictionary != 0) {
      return byDictionary;
    }
    final int byPopularity = b.popularity.compareTo(a.popularity);
    if (byPopularity != 0) {
      return byPopularity;
    }
    return (a.id ?? 0).compareTo(b.id ?? 0);
  }

  @override
  bool operator ==(Object other) => other is DictionaryEntry && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
