import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:tsdm_client/constants/constants.dart';

/// Width of a column of a table in a post, laid out by [PostTableScrollView].
///
/// The natural width of a column is its widest cell on one line, at most [maxWidth]. Its minimum width is [minWidth],
/// or more when a word or an image in it cannot be narrower (see [PostTableImage]), or its natural width when that is
/// narrower. A column wider than twice [minWidth] is long (a description, a title), the others are short (headers,
/// names, numbers).
///
/// These are the intrinsic widths of the table. [PostTableScrollView] decides from them how wide each column is and
/// lays the table out at those widths, the table does not shrink its columns itself: it would shrink them one after
/// the other, the first long column giving up the most room.
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

  double _minWidth(Iterable<RenderBox> cells) {
    final unbreakable = cells.fold<double>(
      0,
      (width, cell) => math.max(width, cell.getMinIntrinsicWidth(double.infinity)),
    );
    return math.min(_naturalWidth(cells), math.max(minWidth, unbreakable));
  }

  _Column _column(Iterable<RenderBox> cells) {
    final natural = _naturalWidth(cells);
    return (natural: natural, min: _minWidth(cells), long: natural > minWidth * 2);
  }

  // The table asks for its intrinsic widths at an unbounded width. Laid out by [PostTableScrollView], it asks at its
  // width for the widths decided there.
  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      _RenderTableViewport._decidedWidth(cells, containerWidth) ?? _naturalWidth(cells);

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      _RenderTableViewport._decidedWidth(cells, containerWidth) ?? _minWidth(cells);

  @override
  String toString() => '${objectRuntimeType(this, 'PostTableColumnWidth')}(min: $minWidth, max: $maxWidth)';
}

/// A column of a table in a post: its natural and minimum widths, and whether it is long (see [PostTableColumnWidth]).
typedef _Column = ({double natural, double min, bool long});

double _sum(Iterable<double> values) => values.fold(0, (sum, value) => sum + value);

/// Widths of [columns] narrowed to [width], which is at least the sum of their minimum widths.
///
/// Long columns give up room first, short ones only what the long ones cannot give. The columns that give up room keep
/// the same share of their natural width: each shrinks in proportion to its natural width, wherever it is in the
/// table. One that reaches its minimum width stays there, the others give up the rest.
List<double> _narrowed(List<_Column> columns, double width) {
  final widths = [for (final column in columns) column.natural];
  var deficit = _sum(widths) - width;
  for (final long in const [true, false]) {
    if (deficit <= precisionErrorTolerance) {
      break;
    }
    deficit = _shrink(columns, widths, [
      for (var x = 0; x < columns.length; x++)
        if (columns[x].long == long) x,
    ], deficit);
  }
  return widths;
}

/// Shrinks the columns [group] of [widths], at their natural widths, by [deficit] as said in [_narrowed]. Returns what
/// they could not give of [deficit].
double _shrink(List<_Column> columns, List<double> widths, List<int> group, double deficit) {
  final room = _sum(group.map((x) => columns[x].natural - columns[x].min));
  if (room <= deficit) {
    for (final x in group) {
      widths[x] = columns[x].min;
    }
    return deficit - room;
  }
  // The share of their natural width the columns keep. A column it would make narrower than its minimum width is kept
  // at its minimum, which leaves less to the others: the share is worked out again without it.
  final target = _sum(group.map((x) => columns[x].natural)) - deficit;
  final atMinimum = <int>{};
  var share = 1.0;
  while (true) {
    final others = group.where((x) => !atMinimum.contains(x));
    share = (target - _sum(atMinimum.map((x) => columns[x].min))) / _sum(others.map((x) => columns[x].natural));
    final reached = others.where((x) => columns[x].natural * share < columns[x].min).toList();
    if (reached.isEmpty) {
      break;
    }
    atMinimum.addAll(reached);
  }
  for (final x in group) {
    widths[x] = atMinimum.contains(x) ? columns[x].min : columns[x].natural * share;
  }
  return 0;
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
/// cells wrapping, when its columns fit at their minimum widths: long columns give up room first, each in proportion
/// to its natural width wherever it is in the table, so headers, names and numbers beside them stay on one line. Only a
/// table that cannot fit even then (many columns, wide images) scrolls sideways, each column at most as wide as the
/// view: a long cell wraps at the width the reader sees, a line is read without scrolling sideways.
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

/// The viewport of a [SingleChildScrollView] scrolling to the right, except for how its child is laid out: in the width
/// it has, and a table at the column widths decided here (see [PostTableScrollView]).
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

  /// The width of each column of [child] by its first cell, while [child] is laid out at the widths decided here.
  Map<RenderBox, double>? _columnWidths;

  /// The width decided for the column of [cells] when the table it is in is laid out by its viewport at
  /// [containerWidth], the width of the table (see [_childLayout]).
  static double? _decidedWidth(Iterable<RenderBox> cells, double containerWidth) {
    if (!containerWidth.isFinite || cells.isEmpty) {
      return null;
    }
    final cell = cells.first;
    final viewport = cell.parent?.parent;
    if (viewport is! _RenderTableViewport) {
      return null;
    }
    return viewport._columnWidths?[cell];
  }

  /// How [child] is laid out in [constraints]: its constraints, and the width of each column when it is a table.
  ///
  /// A table whose cells did not change is not laid out again at the constraints it was last laid out at, so other
  /// column widths come with other constraints: a table that scrolls is at least as wide as the view, one narrowed to
  /// the view or as wide as its cells is not.
  ({BoxConstraints constraints, Map<RenderBox, double>? columnWidths}) _childLayout(
    RenderBox child,
    BoxConstraints constraints,
  ) {
    final heights = constraints.heightConstraints();
    final table = child is RenderTable && child.rows > 0 ? child : null;
    final columns = table == null ? null : _columnsOf(table);
    if (table == null || columns == null) {
      // Not a table of a post: as wide as it is.
      return (constraints: heights, columnWidths: null);
    }
    final width = constraints.maxWidth;
    final List<double> widths;
    final BoxConstraints tableConstraints;
    if (!width.isFinite || _sum(columns.map((e) => e.natural)) <= width + precisionErrorTolerance) {
      // Fits as wide as its cells.
      widths = [for (final column in columns) column.natural];
      tableConstraints = heights.copyWith(maxWidth: _sum(widths));
    } else if (_sum(columns.map((e) => e.min)) <= width + precisionErrorTolerance) {
      // Narrowed to the width, long cells wrap.
      widths = _narrowed(columns, width);
      tableConstraints = heights.copyWith(maxWidth: width);
    } else {
      // Scrolls, a column at most as wide as the view unless a word or an image in it is wider: a line of a long cell
      // is read without scrolling sideways.
      widths = [for (final column in columns) math.max(column.min, math.min(column.natural, width))];
      tableConstraints = heights.copyWith(minWidth: width, maxWidth: _sum(widths));
    }
    return (
      constraints: tableConstraints,
      columnWidths: {
        for (var x = 0; x < table.columns; x++)
          if (table.column(x).isNotEmpty) table.column(x).first: widths[x],
      },
    );
  }

  /// The columns of [table], null when one of them is not a [PostTableColumnWidth].
  static List<_Column>? _columnsOf(RenderTable table) {
    final columnWidths = table.columnWidths;
    final columns = <_Column>[];
    for (var x = 0; x < table.columns; x++) {
      final columnWidth = columnWidths?[x] ?? table.defaultColumnWidth;
      if (columnWidth is! PostTableColumnWidth) {
        return null;
      }
      columns.add(columnWidth._column(table.column(x)));
    }
    return columns;
  }

  /// Runs [layout], a layout of [child], with the column widths of [_childLayout].
  T _withColumnWidths<T>(Map<RenderBox, double>? columnWidths, T Function() layout) {
    final previous = _columnWidths;
    _columnWidths = columnWidths;
    try {
      return layout();
    } finally {
      _columnWidths = previous;
    }
  }

  Size _childDryLayout(RenderBox child, BoxConstraints constraints) {
    final layout = _childLayout(child, constraints);
    return _withColumnWidths(layout.columnWidths, () => child.getDryLayout(layout.constraints));
  }

  @override
  double computeMinIntrinsicWidth(double height) => child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) => child?.getMaxIntrinsicWidth(height) ?? 0;

  // The table is as high as it is laid out in the width.
  @override
  double computeMinIntrinsicHeight(double width) =>
      child == null ? 0 : _childDryLayout(child!, BoxConstraints(maxWidth: width)).height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) {
      return constraints.smallest;
    }
    return constraints.constrain(_childDryLayout(child, constraints));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
    } else {
      final layout = _childLayout(child, constraints);
      _withColumnWidths(layout.columnWidths, () => child.layout(layout.constraints, parentUsesSize: true));
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
