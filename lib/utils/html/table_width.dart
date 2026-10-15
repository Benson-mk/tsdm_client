import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:tsdm_client/constants/constants.dart';

/// Width of a column of a table in a post.
///
/// The natural width of a column is its widest cell on one line, at most [maxWidth]. A table wider than the room it
/// has is narrowed by [PostTableScrollView], each column down to its minimum: [minWidth], or more when a word or an
/// image in it cannot be narrower (see [PostTableImage]), or its natural width when that is narrower.
///
/// Long columns (wider than twice [minWidth]) give up room first, in proportion to their natural width, so a long
/// text wraps while headers, labels and numbers beside it stay on one line. Short columns only shrink when the long
/// ones cannot give more.
class PostTableColumnWidth extends TableColumnWidth {
  /// Constructor.
  const PostTableColumnWidth({this.minWidth = 64, this.maxWidth = htmlContentMaxWidth});

  /// Narrowest a column with long cells is made.
  final double minWidth;

  /// Widest a column is.
  final double maxWidth;

  double _naturalWidth(Iterable<RenderBox> cells) => math.min(
    maxWidth,
    cells.fold<double>(0, (width, cell) => math.max(width, cell.getMaxIntrinsicWidth(double.infinity))),
  );

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) => _naturalWidth(cells);

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    final unbreakable = cells.fold<double>(
      0,
      (width, cell) => math.max(width, cell.getMinIntrinsicWidth(double.infinity)),
    );
    return math.min(_naturalWidth(cells), math.max(minWidth, unbreakable));
  }

  // Flexible columns are shrunk first, in proportion to their flex, when the table is narrowed. A flex never widens a
  // column: the table is only given a maximum width when it is wider than that (see [PostTableScrollView]).
  @override
  double? flex(Iterable<RenderBox> cells) {
    final width = _naturalWidth(cells);
    return width > minWidth * 2 ? width : null;
  }

  @override
  String toString() => '${objectRuntimeType(this, 'PostTableColumnWidth')}(min: $minWidth, max: $maxWidth)';
}

/// An image in a cell of a table in a post.
///
/// An image reports no minimum width, a table narrowed to the screen would shrink it to nothing. In a table it can be
/// narrowed down to [minWidth] (a thumbnail, tap it to see it whole) but not further: a table of wider images scrolls
/// sideways instead. Only the minimum width the table asks for changes, the image is laid out as before.
class PostTableImage extends SingleChildRenderObjectWidget {
  /// Constructor.
  const PostTableImage({required super.child, super.key});

  /// Narrowest an image is made, unless it is narrower than that.
  static const double minWidth = 120;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPostTableImage();
}

class _RenderPostTableImage extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => math.min(PostTableImage.minWidth, getMaxIntrinsicWidth(height));
}

/// Horizontal scroll view of a [Table] in a post whose columns are [PostTableColumnWidth].
///
/// The table is laid out as wide as its cells when that fits. A wider table is narrowed to the width it has, its long
/// cells wrapping, when its columns fit at their minimum widths. Only a table that cannot fit even then (many columns,
/// wide images) scrolls sideways, a long cell still wrapping about at the width it has.
///
/// A [SingleChildScrollView] never tells its child how wide it is, so the table could only be as wide as its cells and
/// a long cell never wrapped. Deciding in the build ([LayoutBuilder]) is no way out: a table can be inside the cell of
/// another table, which asks the size of its cells before laying them out and a [LayoutBuilder] cannot answer that.
class PostTableScrollView extends StatelessWidget {
  /// Constructor.
  const PostTableScrollView({required this.child, super.key});

  /// The table.
  final Widget child;

  @override
  Widget build(BuildContext context) => Scrollable(
    axisDirection: AxisDirection.right,
    viewportBuilder: (context, offset) => _TableViewport(offset: offset, child: child),
  );
}

class _TableViewport extends SingleChildRenderObjectWidget {
  const _TableViewport({required this.offset, super.child});

  final ViewportOffset offset;

  @override
  _RenderTableViewport createRenderObject(BuildContext context) => _RenderTableViewport(offset: offset);

  @override
  void updateRenderObject(BuildContext context, _RenderTableViewport renderObject) => renderObject.offset = offset;

  @override
  SingleChildRenderObjectElement createElement() => _TableViewportElement(this);
}

// Scroll notifications of the table get the depth of a nested scroll view, as in a [SingleChildScrollView].
class _TableViewportElement extends SingleChildRenderObjectElement with NotifiableElementMixin, ViewportElementMixin {
  _TableViewportElement(_TableViewport super.widget);
}

/// The viewport of a [SingleChildScrollView] scrolling to the right, except for the width its child is laid out in.
class _RenderTableViewport extends RenderBox
    with RenderObjectWithChildMixin<RenderBox>
    implements RenderAbstractViewport {
  _RenderTableViewport({required ViewportOffset offset}) : _offset = offset;

  ViewportOffset get offset => _offset;
  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) {
      return;
    }
    if (attached) {
      _offset.removeListener(_hasScrolled);
    }
    _offset = value;
    if (attached) {
      _offset.addListener(_hasScrolled);
    }
    markNeedsLayout();
  }

  void _hasScrolled() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! ParentData) {
      child.parentData = ParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_hasScrolled);
  }

  @override
  void detach() {
    _offset.removeListener(_hasScrolled);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  double get _maxScrollExtent => child == null ? 0 : math.max(0, child!.size.width - size.width);

  /// Constraints of [child] in [constraints], what decides how wide the table is.
  BoxConstraints _childConstraints(RenderBox child, BoxConstraints constraints) {
    final heights = constraints.heightConstraints();
    final width = constraints.maxWidth;
    if (!width.isFinite || child.getMaxIntrinsicWidth(double.infinity) <= width + precisionErrorTolerance) {
      // Fits as wide as its cells.
      return heights;
    }
    final minWidth = child.getMinIntrinsicWidth(double.infinity);
    if (minWidth <= width + precisionErrorTolerance) {
      // Narrowed to the width, long cells wrap.
      return heights.copyWith(maxWidth: width);
    }
    if (child is! RenderTable) {
      return heights;
    }
    // Scrolls, narrowed by as much as its columns are wider than the width: a long cell wraps about where the reader
    // can see it instead of at the width of the website.
    final columnWidths = child.columnWidths;
    var capped = 0.0;
    for (var x = 0; x < child.columns; x++) {
      final columnWidth = columnWidths?[x] ?? child.defaultColumnWidth;
      capped += math.min(width, columnWidth.maxIntrinsicWidth(child.column(x), double.infinity));
    }
    return heights.copyWith(maxWidth: math.max(minWidth, capped));
  }

  @override
  double computeMinIntrinsicWidth(double height) => child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) => child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) => child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) => child?.getMaxIntrinsicHeight(width) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) {
      return constraints.smallest;
    }
    return constraints.constrain(child.getDryLayout(_childConstraints(child, constraints)));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
    } else {
      child.layout(_childConstraints(child, constraints), parentUsesSize: true);
      size = constraints.constrain(child.size);
    }

    if (offset.hasPixels) {
      if (offset.pixels > _maxScrollExtent) {
        offset.correctBy(_maxScrollExtent - offset.pixels);
      } else if (offset.pixels < 0) {
        offset.correctBy(-offset.pixels);
      }
    }
    offset
      ..applyViewportDimension(size.width)
      ..applyContentDimensions(0, _maxScrollExtent);
  }

  Offset get _paintOffset => _paintOffsetForPosition(offset.pixels);

  Offset _paintOffsetForPosition(double position) => Offset(-position, 0);

  bool get _overflows => child != null && child!.size.width > size.width;

  final _clipRectLayer = LayerHandle<ClipRectLayer>();

  @override
  void dispose() {
    _clipRectLayer.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      return;
    }
    final paintOffset = _paintOffset;
    void paintContents(PaintingContext context, Offset offset) => context.paintChild(child, offset + paintOffset);
    if (_overflows || paintOffset.dx != 0) {
      _clipRectLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        paintContents,
        oldLayer: _clipRectLayer.layer,
      );
    } else {
      _clipRectLayer.layer = null;
      paintContents(context, offset);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final paintOffset = _paintOffset;
    transform.translateByDouble(paintOffset.dx, paintOffset.dy, 0, 1);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject? child) =>
      child != null && (_overflows || _paintOffset.dx != 0) ? Offset.zero & size : null;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: _paintOffset,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }

  @override
  RevealedOffset getOffsetToReveal(RenderObject target, double alignment, {Rect? rect, Axis? axis}) {
    rect ??= target.paintBounds;
    if (target is! RenderBox) {
      return RevealedOffset(offset: offset.pixels, rect: rect);
    }
    final bounds = MatrixUtils.transformRect(target.getTransformTo(child), rect);
    final targetOffset = bounds.left - (size.width - bounds.width) * alignment;
    return RevealedOffset(offset: targetOffset, rect: bounds.shift(_paintOffsetForPosition(targetOffset)));
  }

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!offset.allowImplicitScrolling) {
      return super.showOnScreen(descendant: descendant, rect: rect, duration: duration, curve: curve);
    }
    final newRect = RenderViewportBase.showInViewport(
      descendant: descendant,
      viewport: this,
      offset: offset,
      rect: rect,
      duration: duration,
      curve: curve,
    );
    super.showOnScreen(rect: newRect, duration: duration, curve: curve);
  }

  @override
  Rect describeSemanticsClip(RenderObject child) => Rect.fromLTRB(
    semanticBounds.left - offset.pixels,
    semanticBounds.top,
    semanticBounds.right + _maxScrollExtent - offset.pixels,
    semanticBounds.bottom,
  );
}
