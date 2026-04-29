import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:html/dom.dart' as dom;

part 'structured_content.mapper.dart';

/// Used for handling nested content when decoding [StructuredContent].
class ContentHook extends MappingHook {
  /// Initialise this object.
  const ContentHook();

  @override
  Object? beforeDecode(Object? value) {
    if (value is String) {
      return StructuredContentTextNode(text: value);
    } else if (value is List) {
      return StructuredContentChildContent(
        children: value
            .map(StructuredContent.processContent)
            .whereType<StructuredContent>()
            .toList(),
      );
    }

    return value;
  }
}

/// Wraps around all types of possible structured content.
@MappableClass(generateMethods: GenerateMethods.decode)
sealed class StructuredContent with StructuredContentMappable {
  /// Initialise this object.
  const StructuredContent({this.content});

  @MappableField(hook: ContentHook())

  /// Nested content.
  final StructuredContent? content;

  /// Handles nested content.
  static StructuredContent? processContent(var content) {
    if (content is String) {
      return StructuredContentTextNode(text: content);
    } else if (content is List) {
      return StructuredContentChildContent(
          children: content
              .map(processContent)
              .whereType<StructuredContent>()
              .toList());
    } else if (content is Map<String, dynamic>) {
      return StructuredContentMapper.fromMap(content);
    }

    return null;
  }

  /// Convert this to a valid HTML node.
  dom.Node toNode();

  /// Append [content] to [parent], unwrapping a
  /// [StructuredContentChildContent] so its children become direct children
  /// of [parent].
  ///
  /// Without this, a `<ul>` whose Yomitan `content` is an array of `<li>`s
  /// produces `<ul><div><li/></div></ul>` — invalid HTML that confuses
  /// flutter_html's list rendering and leaves stray bullets.
  static void appendContent(dom.Element parent, StructuredContent? content) {
    if (content == null) return;
    if (content is StructuredContentChildContent) {
      for (final child in content.children) {
        parent.append(child.toNode());
      }
    } else {
      parent.append(content.toNode());
    }
  }
}

/// Represents a text node.
@MappableClass(
  discriminatorValue: StructuredContentTextNode.checkType,
)
class StructuredContentTextNode extends StructuredContent
    with StructuredContentTextNodeMappable {
  /// Initialise this object.
  const StructuredContentTextNode({required this.text});

  /// Text for this node.
  final String text;

  @override
  dom.Node toNode() {
    return dom.Text(text);
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is Map && value['text'] != null;
  }
}

/// An array of child content.
@MappableClass(discriminatorValue: StructuredContentChildContent.checkType)
class StructuredContentChildContent extends StructuredContent
    with StructuredContentChildContentMappable {
  /// Initialise this object.
  const StructuredContentChildContent({required this.children});

  /// Children to show.
  final List<StructuredContent> children;

  @override
  dom.Node toNode() {
    final node = dom.Element.tag('div');
    for (final child in children) {
      node.nodes.add(child.toNode());
    }

    return node;
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is List;
  }
}

/// Represents a line break tag.
@MappableClass(discriminatorValue: StructuredContentLineBreak.checkType)
class StructuredContentLineBreak extends StructuredContent
    with StructuredContentLineBreakMappable {
  /// Initialise this object.
  StructuredContentLineBreak();

  @override
  dom.Node toNode() {
    return dom.Element.tag('br');
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is Map && value['tag'] == 'br';
  }
}

/// Represents an image tag.
@MappableClass(discriminatorValue: StructuredContentImage.checkType)
class StructuredContentImage extends StructuredContent
    with StructuredContentImageMappable {
  /// Initialise this object.
  const StructuredContentImage({
    required this.path,
    this.width,
    this.height,
    this.title,
    this.alt,
    this.description,
    this.pixelated = false,
    this.imageRendering = 'auto',
    this.appearance = 'auto',
    this.background = true,
    this.collapsed = false,
    this.collapsible = true,
    this.verticalAlign,
    this.sizeUnits,
    this.border,
    this.borderRadius,
  });

  /// Path to the image file in the archive.
  final String path;

  /// Preferred width of the image.
  final double? width;

  /// Preferred height of the image.
  final double? height;

  /// Hover text for the image.
  final String? title;

  /// Description of the image.
  final String? description;

  /// Whether or not the image should appear pixelated at sizes larger than
  /// the image's native resolution.
  final bool pixelated;

  /// Controls how the image is rendered. The value of this field supersedes
  /// the pixelated field.
  final String imageRendering;

  /// Controls the appearance of the image. The "monochrome" value will mask
  /// the opaque parts of the image using the current text color.
  final String appearance;

  /// Whether or not a background color is displayed behind the image.
  final bool background;

  /// Whether or not the image is collapsed by default.
  final bool collapsed;

  /// Whether or not the image can be collapsed.
  final bool collapsible;

  /// The vertical alignment of the image.
  final String? verticalAlign;

  /// The units for the width and height.
  final String? sizeUnits;

  /// HTML alt text. Per Yomitan spec this is distinct from [description] —
  /// `alt` populates the HTML `alt` attribute, `description` is hover text.
  final String? alt;

  /// CSS `border` shorthand applied as inline style on the `<img>`.
  final String? border;

  /// CSS `border-radius` applied as inline style on the `<img>`.
  final String? borderRadius;

  @override
  dom.Node toNode() {
    final imageNode = dom.Element.tag('img');

    final srcAttr = 'jidoujisho://$path';
    final widthAttr = (width != null) ? '$width${sizeUnits ?? ''}' : null;
    final heightAttr = (height != null) ? '$height${sizeUnits ?? ''}' : null;
    final altAttr = alt ?? description;

    final inlineStyles = <String, String>{};
    if (border != null) inlineStyles['border'] = border!;
    if (borderRadius != null) inlineStyles['border-radius'] = borderRadius!;
    if (verticalAlign != null) inlineStyles['vertical-align'] = verticalAlign!;
    final styleAttr = inlineStyles.isEmpty
        ? null
        : inlineStyles.entries.map((e) => '${e.key}:${e.value};').join();

    imageNode.attributes.addAll(
      {
        'src': srcAttr,
        if (altAttr != null) 'alt': altAttr,
        if (widthAttr != null) 'width': widthAttr,
        if (heightAttr != null) 'height': heightAttr,
        if (styleAttr != null) 'style': styleAttr,
      },
    );

    if (title == null) {
      return imageNode;
    } else {
      final figureNode = dom.Element.tag('figure');
      final figcaptionNode = dom.Element.tag('figcaption')
        ..append(dom.Text(title));

      figureNode
        ..append(imageNode)
        ..append(figcaptionNode);

      return figureNode;
    }
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is Map && (value['tag'] == 'img' || value['type'] == 'image');
  }
}

/// Represents an image tag.
@MappableClass(discriminatorValue: StructuredContentLink.checkType)
class StructuredContentLink extends StructuredContent
    with StructuredContentLinkMappable {
  /// Initialise this object.
  const StructuredContentLink({
    required this.href,
    super.content,
    this.lang,
  });

  /// The URL for the link. URLs starting with a ? are treated as internal
  /// links to other dictionary content.
  final String href;

  /// Defines the language of an element in the format defined by RFC 5646.
  final String? lang;

  @override
  dom.Node toNode() {
    final linkNode = dom.Element.tag('a');

    linkNode.attributes.addAll(
      {
        'href': href,
        if (lang != null) 'lang': lang!,
      },
    );

    StructuredContent.appendContent(linkNode, content);

    return linkNode;
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is Map && (value['tag'] == 'a');
  }
}

/// Generic container tags.
@MappableClass(discriminatorValue: StructuredContentContainer.checkType)
class StructuredContentContainer extends StructuredContent
    with StructuredContentContainerMappable {
  /// Initialise this object.
  const StructuredContentContainer({
    required this.tag,
    super.content,
    this.data,
    this.lang,
  });

  /// [tag] must match one of these tags.
  static List<String> validTags = [
    'ruby',
    'rt',
    'rp',
    'table',
    'thead',
    'tbody',
    'tfoot',
    'tr',
  ];

  /// Tag name. Must be any of the [validTags].
  final String tag;

  /// Additional attributes.
  final Map<String, String>? data;

  /// Defines the language of an element in the format defined by RFC 5646.
  final String? lang;

  @override
  dom.Node toNode() {
    final containerNode = dom.Element.tag(tag);

    containerNode.attributes.addAll({
      if (data != null)
        for (final e in data!.entries) 'data-${e.key}': e.value,
      if (lang != null) 'lang': lang!,
    });

    StructuredContent.appendContent(containerNode, content);

    return containerNode;
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is Map && validTags.contains(value['tag']);
  }
}

/// Stylable generic container tags.
@MappableClass(discriminatorValue: StructuredContentStyledContainer.checkType)
class StructuredContentStyledContainer extends StructuredContent
    with StructuredContentStyledContainerMappable {
  /// Initialise this object.
  const StructuredContentStyledContainer({
    required this.tag,
    super.content,
    this.style,
    this.data,
    this.lang,
    this.title,
    this.open,
  });

  /// [tag] must match one of these tags. `details` and `summary` were added
  /// in the modern Yomitan structured-content spec.
  static List<String> validTags = [
    'span',
    'div',
    'ol',
    'ul',
    'li',
    'details',
    'summary',
  ];

  /// Tag name. Must be any of the [validTags].
  final String tag;

  /// Style for this container.
  final StructuredContentStyle? style;

  /// Additional attributes.
  final Map<String, String>? data;

  /// Defines the language of an element in the format defined by RFC 5646.
  final String? lang;

  /// Hover text (HTML `title` attribute). Yomitan spec allows it on any
  /// styled container.
  final String? title;

  /// For `details` only — whether the disclosure is expanded by default.
  final bool? open;

  @override
  dom.Node toNode() {
    final containerNode = dom.Element.tag(tag);

    containerNode.attributes.addAll({
      if (data != null)
        for (final e in data!.entries) 'data-${e.key}': e.value,
      if (lang != null) 'lang': lang!,
      if (title != null) 'title': title!,
      if (tag == 'details' && open == true) 'open': '',
      if (style != null && style!.toInlineStyle().isNotEmpty)
        'style': style!.toInlineStyle(),
    });

    StructuredContent.appendContent(containerNode, content);

    return containerNode;
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is Map && validTags.contains(value['tag']);
  }
}

/// Table tags.
@MappableClass(discriminatorValue: StructuredContentTableElement.checkType)
class StructuredContentTableElement extends StructuredContent
    with StructuredContentTableElementMappable {
  /// Initialise this object.
  const StructuredContentTableElement({
    required this.tag,
    super.content,
    this.style,
    this.data,
    this.colSpan,
    this.rowSpan,
    this.lang,
  });

  /// [tag] must match one of these tags.
  static List<String> validTags = [
    'td',
    'th',
  ];

  /// Tag name. Must be any of the [validTags].
  final String tag;

  /// Style for this node.
  final StructuredContentStyle? style;

  /// Additional attributes.
  final Map<String, String>? data;

  /// Column span.
  final int? colSpan;

  /// Row span.
  final int? rowSpan;

  /// Defines the language of an element in the format defined by RFC 5646.
  final String? lang;

  @override
  dom.Node toNode() {
    final node = dom.Element.tag(tag);

    node.attributes.addAll({
      if (data != null)
        for (final e in data!.entries) 'data-${e.key}': e.value,
      if (lang != null) 'lang': lang!,
      if (style != null && style!.toInlineStyle().isNotEmpty)
        'style': style!.toInlineStyle(),
      if (colSpan != null) 'colspan': colSpan!.toString(),
      if (rowSpan != null) 'rowSpan': rowSpan!.toString(),
    });

    StructuredContent.appendContent(node, content);

    return node;
  }

  /// Discriminator logic.
  static bool checkType(value) {
    return value is Map && validTags.contains(value['tag']);
  }
}

/// Used to resolve [StructuredContentStyle.textDecorationLine] which can be
/// a [List] or a [String].
class TextDecorationLineHooker extends MappingHook {
  /// Initialise this object.
  const TextDecorationLineHooker();

  @override
  Object? beforeDecode(Object? value) {
    if (value is String) {
      return [value];
    }

    return value;
  }
}

/// Style for a [StructuredContent].
@MappableClass()
class StructuredContentStyle with StructuredContentStyleMappable {
  /// Initialise this object.
  const StructuredContentStyle({
    this.fontStyle,
    this.fontWeight,
    this.fontSize,
    this.color,
    this.background,
    this.backgroundColor,
    this.textDecorationLine,
    this.textDecorationStyle,
    this.textDecorationColor,
    this.verticalAlign,
    this.textAlign,
    this.wordBreak,
    this.whiteSpace,
    this.margin,
    this.marginTop,
    this.marginLeft,
    this.marginRight,
    this.marginBottom,
    this.padding,
    this.paddingTop,
    this.paddingLeft,
    this.paddingRight,
    this.paddingBottom,
    this.borderColor,
    this.borderStyle,
    this.borderWidth,
    this.borderRadius,
    this.listStyleType,
  });

  /// Valid list types recognised by the [list_counter] package — used to
  /// validate dictionary-supplied [listStyleType] values before emitting them.
  static List<String> validListStyleTypes =
      ListStyleType.values.map((e) => e.counterStyle).toList();

  /// Equivalent to 'font-style'.
  final String? fontStyle;

  /// Equivalent to 'font-weight'.
  final String? fontWeight;

  /// Equivalent to 'font-size'.
  final String? fontSize;

  /// Equivalent to 'color'.
  final String? color;

  /// Equivalent to 'background'.
  final String? background;

  /// Equivalent to 'background-color'.
  final String? backgroundColor;

  /// Equivalent to 'text-decoration-line'.
  @MappableField(hook: TextDecorationLineHooker())
  final List<String>? textDecorationLine;

  /// Equivalent to 'text-decoration-style'.
  final String? textDecorationStyle;

  /// Equivalent to 'text-decoration-color'.
  final String? textDecorationColor;

  /// Equivalent to 'vertical-align'.
  final String? verticalAlign;

  /// Equivalent to 'text-align'.
  final String? textAlign;

  /// Equivalent to 'word-break'.
  final String? wordBreak;

  /// Equivalent to 'white-space'.
  final String? whiteSpace;

  /// Equivalent to 'margin' (shorthand).
  final String? margin;

  /// Equivalent to 'margin-top'.
  final double? marginTop;

  /// Equivalent to 'margin-left'.
  final double? marginLeft;

  /// Equivalent to 'margin-right'.
  final double? marginRight;

  /// Equivalent to 'margin-bottom'.
  final double? marginBottom;

  /// Equivalent to 'padding' (shorthand).
  final String? padding;

  /// Equivalent to 'padding-top'.
  final String? paddingTop;

  /// Equivalent to 'padding-left'.
  final String? paddingLeft;

  /// Equivalent to 'padding-right'.
  final String? paddingRight;

  /// Equivalent to 'padding-bottom'.
  final String? paddingBottom;

  /// Equivalent to 'border-color'.
  final String? borderColor;

  /// Equivalent to 'border-style'.
  final String? borderStyle;

  /// Equivalent to 'border-width'.
  final String? borderWidth;

  /// Equivalent to 'border-radius'.
  final String? borderRadius;

  /// Equivalent to 'list-style-type'.
  final String? listStyleType;

  /// Convert margin doubles to a CSS length string (zero stays unitless;
  /// non-zero gets `px`).
  String _marginValue(double value) =>
      value == 0 ? '0' : '${value}px';

  /// Convert this into an inline-style attribute value. Null fields are
  /// skipped — leaving them out so the user-agent / cascade default applies
  /// (this is what fixes Jitendex's `<ol>` getting clobbered with
  /// `list-style-type:square`).
  String toInlineStyle() {
    final attributes = <String, String>{};

    void put(String key, String? value) {
      if (value != null && value.isNotEmpty) attributes[key] = value;
    }

    put('font-style', fontStyle);
    put('font-weight', fontWeight);
    put('font-size', fontSize);
    put('color', color);
    put('background', background);
    put('background-color', backgroundColor);
    final tdl = textDecorationLine;
    if (tdl != null && tdl.isNotEmpty) {
      attributes['text-decoration-line'] = tdl.join(' ');
    }
    put('text-decoration-style', textDecorationStyle);
    put('text-decoration-color', textDecorationColor);
    put('vertical-align', verticalAlign);
    put('text-align', textAlign);
    put('word-break', wordBreak);
    put('white-space', whiteSpace);
    put('margin', margin);
    if (marginTop != null) attributes['margin-top'] = _marginValue(marginTop!);
    if (marginLeft != null) attributes['margin-left'] = _marginValue(marginLeft!);
    if (marginRight != null) {
      attributes['margin-right'] = _marginValue(marginRight!);
    }
    if (marginBottom != null) {
      attributes['margin-bottom'] = _marginValue(marginBottom!);
    }
    put('padding', padding);
    put('padding-top', paddingTop);
    put('padding-left', paddingLeft);
    put('padding-right', paddingRight);
    put('padding-bottom', paddingBottom);
    put('border-color', borderColor);
    put('border-style', borderStyle);
    put('border-width', borderWidth);
    put('border-radius', borderRadius);
    if (listStyleType != null) {
      // Pass through CSS keywords (disc, circle, decimal, ...) and CSS3
      // quoted-string markers ('🇯🇵 ') alike. Quoted strings are handled by
      // a post-processor in the renderer that inlines them as text — the
      // attribute needs to survive long enough to reach that pass.
      final isQuoted = (listStyleType!.startsWith("'") &&
              listStyleType!.endsWith("'")) ||
          (listStyleType!.startsWith('"') && listStyleType!.endsWith('"'));
      if (validListStyleTypes.contains(listStyleType) || isQuoted) {
        attributes['list-style-type'] = listStyleType!;
      }
    }

    return attributes.entries.map((e) => '${e.key}:${e.value};').join();
  }
}
