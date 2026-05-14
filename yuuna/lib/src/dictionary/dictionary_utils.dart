import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/models.dart';

/// FNV-1a 64bit hash algorithm optimized for Dart Strings.
/// This is used to generate integer IDs that can be hard assigned to entities
/// with string IDs with microscopically low collision. This allows for example,
/// a [DictionaryHeading]'s ID to always be determinable by its composite
/// parameters.
int fastHash(String string) {
  var hash = 0xcbf29ce484222325;

  var i = 0;
  while (i < string.length) {
    final codeUnit = string.codeUnitAt(i++);
    hash ^= codeUnit >> 8;
    hash *= 0x100000001b3;
    hash ^= codeUnit & 0xFF;
    hash *= 0x100000001b3;
  }

  return hash;
}

/// Performed in another isolate with compute. This is a top-level utility
/// function that makes use of Isar allowing instances to be opened through
/// multiple isolates. The function for preparing entries and tags according to
/// the [DictionaryFormat] is also done in the same isolate, to remove having
/// to communicate potentially hundreds of thousands of entries to another
/// newly opened isolate.
///
/// Each prepare* function owns its own write transactions (Yomichan does this
/// via an internal `_ImportBatcher` that flushes ~10000 rows at a time with
/// `putAllSync`; Migaku and ABBYY wrap their bodies in a single `writeTxnSync`
/// each). Atomicity across the whole import is preserved by deleting the
/// half-imported dictionary's rows in the catch block — failed imports leave
/// no trace, matching the previous single-transaction behaviour.
Future<void> depositDictionaryDataHelper(PrepareDictionaryParams params) async {
  Isar? isar;
  try {
    isar = await Isar.open(
      globalSchemas,
      directory: params.directoryPath,
      maxSizeMiB: 8192,
    );

    // Write the dictionary metadata row up front in its own small txn so
    // subsequent `IsarLink.value = params.dictionary` references resolve once
    // the owning entries/tags/pitches/frequencies are flushed.
    isar.writeTxnSync(() {
      isar!.dictionarys.putSync(params.dictionary);
    });

    params.dictionaryFormat.prepareTags(params: params, isar: isar);
    params.dictionaryFormat.prepareEntries(params: params, isar: isar);
    params.dictionaryFormat.preparePitches(params: params, isar: isar);
    params.dictionaryFormat.prepareFrequencies(params: params, isar: isar);

    // Drain any pending writes still held by the Yomichan batcher. No-op for
    // formats that don't use it.
    finalizeYomichanImport(isar: isar);
  } catch (e, stack) {
    debugPrint('$e');
    debugPrint('$stack');
    params.send('$stack');

    // Roll back: drop everything tied to this dictionary id so a retried
    // import doesn't see half-imported state. Best-effort — if the rollback
    // itself fails, the original error still surfaces below via rethrow.
    abandonYomichanImport();
    if (isar != null) {
      try {
        final int id = params.dictionary.id;
        isar.writeTxnSync(() {
          isar!.dictionaryEntrys
              .filter()
              .dictionary((q) => q.idEqualTo(id))
              .deleteAllSync();
          isar.dictionaryTags
              .filter()
              .dictionary((q) => q.idEqualTo(id))
              .deleteAllSync();
          isar.dictionaryPitchs
              .filter()
              .dictionary((q) => q.idEqualTo(id))
              .deleteAllSync();
          isar.dictionaryFrequencys
              .filter()
              .dictionary((q) => q.idEqualTo(id))
              .deleteAllSync();
          // Drop headings that no other dictionary still references — same
          // condition as `deleteDictionaryHelper` so co-owned headings stay.
          isar.dictionaryHeadings
              .filter()
              .entriesIsEmpty()
              .and()
              .tagsIsEmpty()
              .and()
              .pitchesIsEmpty()
              .and()
              .frequenciesIsEmpty()
              .deleteAllSync();
          isar.dictionarys.deleteSync(id);
        });
      } catch (rollbackError, rollbackStack) {
        debugPrint('rollback failed: $rollbackError');
        debugPrint('$rollbackStack');
      }
    }

    rethrow;
  }
}

/// Preloads the entities linked to a search result.
void preloadResultSync(int id) {
  /// Create a new instance of Isar as this is a different isolate.
  final Isar database = Isar.getInstance()!;
  DictionarySearchResult result = database.dictionarySearchResults.getSync(id)!;

  result.headings.loadSync();

  for (DictionaryHeading heading in result.headings) {
    heading.entries.loadSync();
    for (DictionaryEntry entry in heading.entries) {
      entry.dictionary.loadSync();
      entry.tags.loadSync();
    }
    heading.pitches.loadSync();
    heading.frequencies.loadSync();
    for (DictionaryFrequency frequency in heading.frequencies) {
      frequency.dictionary.loadSync();
    }
    heading.tags.loadSync();
  }
}

/// Add a [DictionarySearchResult] to the dictionary history. If the maximum value
/// is exceed, the dictionary history is cut down to the newest values.
Future<void> updateDictionaryHistoryHelper(
  UpdateDictionaryHistoryParams params,
) async {
  final Isar database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  DictionarySearchResult result =
      database.dictionarySearchResults.getSync(params.resultId)!;

  database.writeTxnSync(() {
    result.scrollPosition = params.newPosition;
    database.dictionarySearchResults.putSync(result);
  });
}

/// Clears all data from the dictionary database.
Future<void> deleteDictionariesHelper(DeleteDictionaryParams params) async {
  final Isar database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  database.writeTxnSync(() {
    database.dictionarySearchResults.clearSync();
    database.dictionaryTags.clearSync();
    database.dictionaryEntrys.clearSync();
    database.dictionaryHeadings.clearSync();
    database.dictionaryPitchs.clearSync();
    database.dictionaryFrequencys.clearSync();
    database.dictionarys.clearSync();
  });
}

/// Clears single dictionary data from the dictionary database.
Future<void> deleteDictionaryHelper(DeleteDictionaryParams params) async {
  final Isar database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  int id = params.dictionaryId!;
  Dictionary dictionary = database.dictionarys.getSync(id)!;

  database.writeTxnSync(() {
    database.dictionarySearchResults.clearSync();
    database.dictionaryEntrys
        .filter()
        .dictionary((q) => q.idEqualTo(id))
        .deleteAllSync();
    database.dictionaryTags
        .filter()
        .dictionary((q) => q.idEqualTo(id))
        .deleteAllSync();
    database.dictionaryPitchs
        .filter()
        .dictionary((q) => q.idEqualTo(id))
        .deleteAllSync();
    database.dictionaryFrequencys
        .filter()
        .dictionary((q) => q.idEqualTo(id))
        .deleteAllSync();
    database.dictionaryHeadings
        .filter()
        .entriesIsEmpty()
        .and()
        .tagsIsEmpty()
        .and()
        .pitchesIsEmpty()
        .and()
        .frequenciesIsEmpty()
        .deleteAllSync();
    database.dictionarys.deleteSync(dictionary.id);
  });
}
