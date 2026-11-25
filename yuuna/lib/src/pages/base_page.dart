import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spaces/spaces.dart';
import 'package:yuuna/models.dart';
import 'package:yuuna/utils.dart';

/// A page template which assumes use of [BasePageState] by which all pages
/// in the app will conveniently share base functionality.
abstract class BasePage extends ConsumerStatefulWidget {
  /// Create an instance of this page.
  const BasePage({super.key});

  @override
  BasePageState<BasePage> createState() => BasePageState();
}

/// A base class for providing all pages in the app with a collection
/// of shared functions and variables. In large part, this was implemented to
/// define shortcuts for common lengthy methods across UI code.
class BasePageState<T extends BasePage> extends ConsumerState<T> {
  /// Access the global model responsible for app-wide state management.
  AppModel get appModel =>
      _canUseRef ? _appModel = ref.watch(appProvider) : _appModel;

  /// Access the global model responsible for creator state management.
  CreatorModel get creatorModel => _canUseRef
      ? _creatorModel = ref.watch(creatorProvider)
      : _creatorModel;

  /// Access the global model responsible for app-wide state management without
  /// listening to state updates. Useful when accessing state from [initState].
  AppModel get appModelNoUpdate =>
      _canUseRef ? _appModel = ref.read(appProvider) : _appModel;

  /// Access the global model responsible for creator state management. without
  /// listening to state updates. Useful when accessing state from [initState].
  CreatorModel get creatorModelNoUpdate => _canUseRef
      ? _creatorModel = ref.read(creatorProvider)
      : _creatorModel;

  /// Last models read through [ref]. Flutter clears the element's widget
  /// before calling [dispose], and riverpod throws `Cannot use "ref" after
  /// the widget was disposed` from then on, so any `dispose` that touched
  /// [appModel] (removing listeners, closing audio players) used to throw
  /// and skip the rest of its cleanup, including `super.dispose()`. Both
  /// providers are app-lifetime singletons, so the cached instances are the
  /// same objects [ref] would return.
  late AppModel _appModel;
  late CreatorModel _creatorModel;

  bool get _canUseRef => mounted && context.mounted;

  @override
  void initState() {
    super.initState();
    _appModel = ref.read(appProvider);
    _creatorModel = ref.read(creatorProvider);
  }

  /// Shortcut for accessing the app-wide theme-defined text theme.
  TextTheme get textTheme => Theme.of(context).textTheme;

  /// Shortcut for accessing the app-wide theme.
  ThemeData get theme => Theme.of(context);

  /// Get the selection controls for a [SelectableText].
  MaterialTextSelectionControls get selectionControls =>
      JidoujishoTextSelectionControls(
        searchAction: onSearch,
        stashAction: onStash,
        shareAction: onShare,
        allowCopy: true,
        allowSelectAll: true,
        allowCut: true,
        allowPaste: true,
      );

  /// Action to perform upon using the Search context option.
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
  }

  /// Action to perform upon using the Share context option.
  void onShare(String searchTerm, {String? sentence = ''}) async {
    Share.share(searchTerm);
  }

  /// Action to perform upon using the Stash context option.
  void onStash(String searchTerm) {
    appModel.addToStash(terms: [searchTerm]);
  }

  @override
  Widget build(BuildContext context) {
    throw UnimplementedError();
  }

  /// Standard error message for use across the application.
  /// General widget for showing an error or a retry screen.
  Widget buildError({
    Object? error,
    StackTrace? stack,
    Function()? refresh,
  }) {
    return Center(
      child: JidoujishoPlaceholderMessage(
        icon: Icons.error,
        message: '$error',
      ),
    );
  }

  /// Standard loading circle for use across the application.
  Widget buildLoading() {
    return Center(
      child: SizedBox(
        height: Spacing.of(context).spaces.big,
        width: Spacing.of(context).spaces.big,
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
        ),
      ),
    );
  }
}
