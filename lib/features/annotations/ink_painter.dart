import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'ink.dart';
import 'pen_preset.dart';

/// A conservative midpoint smoother with pressure-varying segments.
/// Kept separate so stored samples never depend on the painting algorithm.
class StrokeSmoother {
  static void paint(Canvas canvas, Size size, List<InkPoint> points,
      double width, Color color, {InkKind kind = InkKind.pen,
      InkShape shape = InkShape.freehand, PenStyle? penStyle,
      int startSegment = 1, int? endSegment}) {
    if (points.isEmpty) return;
    final highlighting = kind == InkKind.highlighter || penStyle?.type == PenType.highlighter;
    if (highlighting || shape != InkShape.freehand) {
      // One path gives the marker uniform opacity, including self-overlaps.
      final paint = Paint()
        ..color = highlighting ? color.withValues(alpha: .3) : color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final first = points.first.inSize(size);
      if (points.length == 1) {
        canvas.drawCircle(first, width / 2, paint..style = PaintingStyle.fill);
        return;
      }
      final path = Path()..moveTo(first.dx, first.dy);
      for (final point in points.skip(1)) {
        final next = point.inSize(size);
        path.lineTo(next.dx, next.dy);
      }
      canvas.drawPath(path, paint);
      return;
    }
    final paint = Paint()..color = color..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    double pointWidth(InkPoint p, int index) {
      if (penStyle == null) return width * (.4 + p.pressure * .8);
      final style = penStyle;
      final response = switch (style.type) {
        PenType.ball => .3, PenType.fountain => .8, PenType.brush => 1.3, PenType.highlighter => 0,
      };
      final pressure = 1 + (p.pressure - .75) * 2 * style.pressureSensitivity * response;
      var nib = 1.0;
      if (style.type == PenType.fountain && points.length > 1) {
        final a = points[math.max(0, index - 1)].inSize(size);
        final b = points[math.min(points.length - 1, index + 1)].inSize(size);
        final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
        nib = 1 - style.tipSharpness * .65 * math.cos(angle - math.pi / 4).abs();
      } else if (style.type == PenType.brush && points.length > 1) {
        final edge = math.min(index, points.length - 1 - index) / math.min(6, points.length / 2);
        nib = 1 - style.tipSharpness * .8 * (1 - edge.clamp(0.0, 1.0));
      } else if (style.type == PenType.ball) {
        nib = 1 - style.tipSharpness * .2;
      }
      return width * math.max(.08, pressure) * nib;
    }
    if (points.length == 1) {
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(points.first.inSize(size), pointWidth(points.first, 0) / 2, paint);
      return;
    }
    var start = startSegment == 1 ? points.first.inSize(size) :
      (points[startSegment - 2].inSize(size) + points[startSegment - 1].inSize(size)) / 2;
    for (var i = startSegment; i < (endSegment ?? points.length); i++) {
      final control = points[i - 1].inSize(size);
      final next = points[i].inSize(size);
      final end = i == points.length - 1 ? next : (control + next) / 2;
      paint.strokeWidth = math.max(.1, (pointWidth(points[i - 1], i - 1) + pointWidth(points[i], i)) / 2);
      canvas.drawPath(Path()..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy), paint);
      start = end;
    }
  }
}

/// Own pictures for precisely the lifetime of a mounted surface. Thumbnails
/// have separate caches so their size cannot invalidate the main canvas cache.
class CommittedInk extends StatefulWidget {
  const CommittedInk({super.key, required this.editor, required this.page,
    required this.pageWidth, this.hidden = const {},
    this.surface = InkSurface.page, this.referenceSize});
  final EditorController editor;
  final int page;
  final double pageWidth;
  final Set<String> hidden;
  final InkSurface surface;
  final Size? referenceSize;

  @override
  State<CommittedInk> createState() => _CommittedInkState();
}

class _CommittedInkState extends State<CommittedInk> {
  final _cache = CommittedInkCache();

  @override
  void didUpdateWidget(CommittedInk oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editor != widget.editor || oldWidget.page != widget.page ||
        oldWidget.surface != widget.surface) _cache.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(painter: CommittedInkPainter(
    widget.editor, widget.page, widget.pageWidth, hidden: widget.hidden,
    surface: widget.surface, referenceSize: widget.referenceSize, cache: _cache,
    devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? View.of(context).devicePixelRatio));

  @override
  void dispose() { _cache.dispose(); super.dispose(); }
}

/// Saved strokes are immutable. Reuse unchanged groups by identity even when
/// an earlier erase or undo shifts their indices. Keep each highlighter whole
/// to preserve its uniform opacity and retain the original stroke paint order.
class CommittedInkCache {
  static const _maxStrokes = 32;
  static const _maxPoints = 4096;
  List<_CommittedInkChunk> _chunks = [];
  Size? _size;
  double? _pageWidth;
  ui.Image? _image;
  Size? _surfaceSize;
  Size? _imageSize;
  List<InkStroke> _rasterStrokes = const [];
  bool _rasterFailed = false;
  // Bound GPU memory even at extreme zoom or on very wide note surfaces.
  static const maxRasterPixels = 2000000;
  static const maxRasterDimension = 4096;

  @visibleForTesting
  int debugRecordedStrokes = 0;
  @visibleForTesting
  int get debugPictureCount => _chunks.length;
  @visibleForTesting
  int debugRasterizations = 0;
  @visibleForTesting
  int debugRasterizedStrokes = 0;
  @visibleForTesting
  ui.Image? get debugImage => _image;

  void paint(Canvas canvas, Size size, double pageWidth, List<InkStroke> strokes,
      {Size? surfaceSize, double? devicePixelRatio}) {
    if (_size != size || _pageWidth != pageWidth) {
      dispose();
      _size = size;
      _pageWidth = pageWidth;
    }
    final indices = <InkStroke, int>{
      for (var i = 0; i < strokes.length; i++) strokes[i]: i,
    };
    final reusable = <InkStroke, _CommittedInkChunk>{};
    for (final chunk in _chunks) {
      final start = indices[chunk.strokes.first];
      if (start == null || start + chunk.strokes.length > strokes.length) continue;
      // Fill the last partial group on append, rather than retaining one
      // picture per pen-up. Earlier complete groups stay untouched.
      if (identical(chunk, _chunks.last) && chunk.strokes.length < _maxStrokes &&
          chunk.pointCount < _maxPoints && start + chunk.strokes.length < strokes.length) continue;
      var matches = true;
      for (var i = 0; i < chunk.strokes.length; i++) {
        if (!identical(chunk.strokes[i], strokes[start + i])) { matches = false; break; }
      }
      if (matches) reusable[chunk.strokes.first] = chunk;
    }

    final next = <_CommittedInkChunk>[];
    for (var start = 0; start < strokes.length;) {
      final cached = reusable[strokes[start]];
      if (cached != null) {
        next.add(cached);
        start += cached.strokes.length;
        continue;
      }
      var end = start;
      var points = 0;
      do {
        points += strokes[end].points.length;
        end++;
      } while (end < strokes.length && end - start < _maxStrokes &&
          points < _maxPoints && !reusable.containsKey(strokes[end]));
      final group = strokes.sublist(start, end);
      final recorder = ui.PictureRecorder();
      final recording = Canvas(recorder);
      for (final stroke in group) {
        _paintCommittedStroke(recording, size, pageWidth, stroke);
      }
      next.add(_CommittedInkChunk(group, points, recorder.endRecording()));
      assert(() { debugRecordedStrokes += group.length; return true; }());
      start = end;
    }
    final retained = next.toSet();
    for (final chunk in _chunks) {
      if (!retained.contains(chunk)) chunk.picture.dispose();
    }
    _chunks = next;
    if (devicePixelRatio != null && _paintRaster(canvas, surfaceSize ?? size,
        size, pageWidth, strokes, devicePixelRatio)) return;
    for (final chunk in _chunks) { canvas.drawPicture(chunk.picture); }
  }

  /// A retained Picture is still a list of vector commands. Cache the final
  /// transparent pixels explicitly so scrolling submits one image, independent
  /// of stroke count and the engine's automatic raster-cache heuristics.
  bool _paintRaster(Canvas canvas, Size surface, Size reference, double pageWidth,
      List<InkStroke> strokes, double dpr) {
    if (strokes.isEmpty || surface.isEmpty) {
      _disposeRaster();
      return true;
    }
    if (!surface.width.isFinite || !surface.height.isFinite || !dpr.isFinite || dpr <= 0) return false;
    final scale = math.min(dpr, math.min(
      math.sqrt(maxRasterPixels / (surface.width * surface.height)),
      maxRasterDimension / math.max(surface.width, surface.height)));
    final pixels = Size(math.max(1, (surface.width * scale).floor()).toDouble(),
      math.max(1, (surface.height * scale).floor()).toDouble());
    final sameSize = _surfaceSize == surface && _imageSize == pixels;
    final sameStrokes = listEquals(_rasterStrokes, strokes);
    if (!sameSize || !sameStrokes) {
      _rasterFailed = false;
      final appendOnly = sameSize && _image != null &&
        strokes.length > _rasterStrokes.length &&
        Iterable<int>.generate(_rasterStrokes.length).every(
          (i) => identical(strokes[i], _rasterStrokes[i]));
      final recorder = ui.PictureRecorder();
      final recording = Canvas(recorder);
      recording.scale(pixels.width / surface.width, pixels.height / surface.height);
      if (appendOnly) {
        // Keep old ink at exactly the same pixel grid; rasterize only new ink.
        recording.drawImageRect(_image!, Offset.zero & pixels, Offset.zero & surface,
          Paint()..filterQuality = FilterQuality.none);
        for (final stroke in strokes.skip(_rasterStrokes.length)) {
          _paintCommittedStroke(recording, reference, pageWidth, stroke);
        }
      } else {
        for (final chunk in _chunks) { recording.drawPicture(chunk.picture); }
      }
      final picture = recorder.endRecording();
      ui.Image? nextImage;
      try {
        nextImage = picture.toImageSync(pixels.width.toInt(), pixels.height.toInt());
        assert(() {
          debugRasterizations++;
          debugRasterizedStrokes += appendOnly ? strokes.length - _rasterStrokes.length : strokes.length;
          return true;
        }());
      } on ui.PictureRasterizationException {
        _rasterFailed = true;
      } finally {
        picture.dispose();
      }
      _image?.dispose();
      _image = nextImage;
      _surfaceSize = surface;
      _imageSize = pixels;
      _rasterStrokes = List.of(strokes);
    }
    if (_rasterFailed || _image == null) return false;
    try {
      canvas.drawImageRect(_image!, Offset.zero & pixels, Offset.zero & surface,
        Paint()..filterQuality = FilterQuality.low);
      return true;
    } on ui.PictureRasterizationException {
      // Deferred rasterization can fail when a GPU context is unavailable.
      // Keep vector ink visible, and retry only after an edit/size change.
      _image?.dispose();
      _image = null;
      _rasterFailed = true;
      return false;
    }
  }

  void _disposeRaster() {
    _image?.dispose();
    _image = null;
    _surfaceSize = null;
    _imageSize = null;
    _rasterStrokes = const [];
    _rasterFailed = false;
  }

  void dispose() {
    _disposeRaster();
    for (final chunk in _chunks) { chunk.picture.dispose(); }
    _chunks = [];
    _size = null;
    _pageWidth = null;
  }
}

class _CommittedInkChunk {
  const _CommittedInkChunk(this.strokes, this.pointCount, this.picture);
  final List<InkStroke> strokes;
  final int pointCount;
  final ui.Picture picture;
}

void _paintCommittedStroke(Canvas canvas, Size size, double pageWidth, InkStroke stroke) {
  StrokeSmoother.paint(canvas, size, stroke.points,
    stroke.width * size.width / pageWidth, Color(stroke.color),
    kind: stroke.kind, shape: stroke.shape, penStyle: stroke.penStyle);
}

class CommittedInkPainter extends CustomPainter {
  CommittedInkPainter(this.editor, this.page, this.pageWidth, {this.hidden = const {},
    this.surface = InkSurface.page, this.referenceSize, this.cache, this.devicePixelRatio})
      : super(repaint: editor.inkSignal(page, surface));
  final EditorController editor;
  final int page;
  final double pageWidth;
  final Set<String> hidden;
  final InkSurface surface;
  final Size? referenceSize;
  final CommittedInkCache? cache;
  final double? devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final strokes = editor.strokes(page).where((stroke) =>
      stroke.surface == surface && !hidden.contains(stroke.id));
    final reference = referenceSize ?? size;
    if (cache != null) {
      cache!.paint(canvas, reference, pageWidth, strokes.toList(),
        surfaceSize: size, devicePixelRatio: devicePixelRatio);
    } else {
      for (final stroke in strokes) { _paintCommittedStroke(canvas, reference, pageWidth, stroke); }
    }
  }

  @override
  bool shouldRepaint(CommittedInkPainter old) => old.editor != editor ||
      old.page != page || old.pageWidth != pageWidth || !setEquals(old.hidden, hidden) ||
      old.surface != surface || old.referenceSize != referenceSize || old.cache != cache ||
      old.devicePixelRatio != devicePixelRatio;
}

class ActiveInk extends ChangeNotifier {
  bool nativePreview = false;
  int? page;
  InkSurface surface = InkSurface.page;
  double width = 2;
  int color = 0xff2947c7;
  InkKind kind = InkKind.pen;
  PenStyle? penStyle;
  final points = <InkPoint>[];
  // Speculative samples are never part of the stored stroke or stable cache.
  List<InkPoint> prediction = const [];
  final _renderer = _LiveStrokeRenderer();
  void changed() => notifyListeners();
  void clear() { page = null; nativePreview = false; points.clear(); prediction = const []; _renderer.reset(); notifyListeners(); }
  @override
  void dispose() { _renderer.reset(); super.dispose(); }
}

class ActiveInkPainter extends CustomPainter {
  ActiveInkPainter(this.ink, this.page, this.pageWidth,
    {this.surface = InkSurface.page, this.referenceSize}) : super(repaint: ink);
  final ActiveInk ink;
  final int page;
  final double pageWidth;
  final InkSurface surface;
  final Size? referenceSize;

  @override
  void paint(Canvas canvas, Size size) {
    final reference = referenceSize ?? size;
    if (!ink.nativePreview && ink.page == page && ink.surface == surface) ink._renderer.paint(canvas, reference, ink.points,
        ink.width * reference.width / pageWidth, Color(ink.color), kind: ink.kind,
        penStyle: ink.penStyle, prediction: ink.prediction);
  }

  @override
  bool shouldRepaint(ActiveInkPainter old) => old.ink != ink || old.page != page ||
      old.pageWidth != pageWidth || old.surface != surface || old.referenceSize != referenceSize;
}


/// Cache stable geometry in small pictures. Fountain nib direction needs adjacent
/// samples; brush taper changes the last six samples, so keep eight in the live tail.
/// Pictures belong to the gesture, not the widget, and survive writing-area rebuilds.
class _LiveStrokeRenderer {
  static const _chunkSegments = 128;
  static const _tailSamples = 8;
  final _chunks = <ui.Picture>[];
  int _nextSegment = 1;
  int _lastCount = 0;
  Size? _size;
  double? _width;
  Color? _color;
  InkKind? _kind;
  PenStyle? _style;
  Path _markerPath = Path();
  int _markerCount = 0;

  void reset() {
    for (final picture in _chunks) { picture.dispose(); }
    _chunks.clear();
    _nextSegment = 1;
    _lastCount = 0;
    _markerPath = Path();
    _markerCount = 0;
    _size = null;
  }

  void paint(Canvas canvas, Size size, List<InkPoint> points, double width, Color color,
      {required InkKind kind, PenStyle? penStyle, List<InkPoint> prediction = const []}) {
    if (points.isEmpty) return;
    if (_size != size || _width != width || _color != color || _kind != kind ||
        _style != penStyle || points.length < _lastCount) {
      reset();
      _size = size;
      _width = width;
      _color = color;
      _kind = kind;
      _style = penStyle;
    }
    _lastCount = points.length;
    if (kind == InkKind.highlighter || penStyle?.type == PenType.highlighter) {
      // One path preserves uniform translucency at retraced sections and joins.
      for (var i = _markerCount; i < points.length; i++) {
        final p = points[i].inSize(size);
        if (i == 0) { _markerPath.moveTo(p.dx, p.dy); }
        else { _markerPath.lineTo(p.dx, p.dy); }
      }
      _markerCount = points.length;
      final paint = Paint()..color = color.withValues(alpha: .3)
        ..style = PaintingStyle.stroke..strokeWidth = width
        ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
      // Append the temporary tip to a copy, then draw once. Drawing two paths
      // would darken the overlap where confirmed and predicted ink meet.
      final path = prediction.isEmpty ? _markerPath : Path.from(_markerPath);
      for (final point in prediction) {
        final p = point.inSize(size);
        path.lineTo(p.dx, p.dy);
      }
      if (points.length == 1 && prediction.isEmpty) {
        canvas.drawCircle(points.first.inSize(size), width / 2, paint..style = PaintingStyle.fill);
      } else { canvas.drawPath(path, paint); }
      return;
    }
    final stableEnd = points.length - _tailSamples;
    while (_nextSegment + _chunkSegments <= stableEnd) {
      final recorder = ui.PictureRecorder();
      StrokeSmoother.paint(Canvas(recorder), size, points, width, color,
        kind: kind, penStyle: penStyle, startSegment: _nextSegment,
        endSegment: _nextSegment + _chunkSegments);
      _chunks.add(recorder.endRecording());
      _nextSegment += _chunkSegments;
    }
    for (final picture in _chunks) { canvas.drawPicture(picture); }
    StrokeSmoother.paint(canvas, size, prediction.isEmpty ? points : _PreviewPoints(points, prediction), width, color,
      kind: kind, penStyle: penStyle, startSegment: _nextSegment);
  }
}

/// Read-only concatenation: extending the live tail must not copy a long stroke.
class _PreviewPoints extends ListBase<InkPoint> {
  _PreviewPoints(this.actual, this.predicted);
  final List<InkPoint> actual;
  final List<InkPoint> predicted;
  @override
  int get length => actual.length + predicted.length;
  @override
  InkPoint operator [](int index) => index < actual.length ? actual[index] : predicted[index - actual.length];
  @override
  set length(int value) => throw UnsupportedError('Read-only ink preview');
  @override
  void operator []=(int index, InkPoint value) => throw UnsupportedError('Read-only ink preview');
}
