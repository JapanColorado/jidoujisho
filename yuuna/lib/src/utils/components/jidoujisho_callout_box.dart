import 'package:flutter/material.dart';

/// A small rounded container with an optional tap action and optional left
/// accent border — used in dictionary entries to render Yomichan/Jitendex
/// callouts (See also, Note, Example sentence).
///
/// The variant is controlled by [accent] (border + tint colour),
/// [hasLeftBorder] (Note + See-also use a left bar; Example sentences don't),
/// and [tintAlpha] (alpha applied to [accent] for the background — replaced
/// by [solidFill] when a flat neutral fill is wanted instead).
class JidoujishoCalloutBox extends StatelessWidget {
  /// Build a callout box. Defaults render a tinted box with a left accent
  /// bar and no tap action.
  const JidoujishoCalloutBox({
    required this.accent,
    required this.child,
    this.onTap,
    this.hasLeftBorder = true,
    this.solidFill,
    this.tintAlpha = 0.08,
    super.key,
  });

  /// Accent colour (left bar + tinted background when [solidFill] is null).
  final Color accent;

  /// Whether to render the left accent bar.
  final bool hasLeftBorder;

  /// If set, this colour is used for the background instead of [accent] tinted
  /// at [tintAlpha]. Use for example-sentence callouts where we want a flat
  /// neutral fill.
  final Color? solidFill;

  /// Alpha applied to [accent] for the tinted background fill. Ignored when
  /// [solidFill] is set.
  final double tintAlpha;

  /// Tap callback for the whole box. Pass null to make non-interactive.
  final VoidCallback? onTap;

  /// Inner content. Anything renderable.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(4);
    final box = Container(
      decoration: BoxDecoration(
        color: solidFill ?? accent.withValues(alpha: tintAlpha),
        border: hasLeftBorder
            ? Border(left: BorderSide(width: 4, color: accent))
            : null,
        borderRadius: radius,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: child,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: onTap == null
          ? box
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                child: box,
              ),
            ),
    );
  }
}
