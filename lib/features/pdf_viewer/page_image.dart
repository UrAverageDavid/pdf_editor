import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'render_service.dart';

class PageImage extends StatefulWidget {
  const PageImage({super.key, required this.renders, required this.page,
    required this.scale, this.priority = 1, this.deferRendering = false});
  final RenderService renders;
  final int page;
  final double scale;
  final int priority;
  final bool deferRendering;
  @override
  State<PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<PageImage> {
  RenderTicket? _ticket;
  ui.Image? _image;
  Object? _error;

  @override
  void initState() { super.initState(); unawaited(_load()); }

  @override
  void didUpdateWidget(PageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.deferRendering && oldWidget.page == widget.page &&
        oldWidget.renders == widget.renders) return;
    if (oldWidget.page != widget.page || oldWidget.renders != widget.renders ||
        oldWidget.deferRendering ||
        (oldWidget.scale * 4).ceil() != (widget.scale * 4).ceil()) {
      unawaited(_load());
    } else { _ticket?.priority = widget.priority; }
  }

  Future<void> _load() async {
    _ticket?.cancel();
    final ticket = widget.renders.request(widget.page, widget.scale, priority: widget.priority);
    _ticket = ticket;
    _error = null;
    try {
      final image = await ticket.result;
      if (image == null) return;
      if (!mounted || _ticket != ticket) { image.dispose(); return; }
      final old = _image;
      setState(() => _image = image);
      // RawImage may still reference the old image until the next build.
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    } catch (error) {
      if (mounted && _ticket == ticket) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _ticket?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: _image != null
        ? RawImage(image: _image, fit: BoxFit.fill, filterQuality: FilterQuality.medium)
        : Center(child: _error != null
          ? TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Retry page'))
          : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
  );
}

/// Sharp visible tiles over the inexpensive whole-page preview. Tile requests
/// are mounted only after navigation settles, avoiding obsolete zoom renders.
class PageTiles extends StatelessWidget {
  const PageTiles({super.key, required this.renders, required this.page,
    required this.scale, required this.displaySize, required this.visibleRect});
  final RenderService renders;
  final int page;
  final double scale;
  final Size displaySize;
  final Rect visibleRect;
  static const tileSide = 512;

  @override
  Widget build(BuildContext context) {
    final pageSize = renders.document.pageSizes[page];
    final pixels = pageSize * scale;
    // Below the preview limit the whole-page image is already sharp.
    if (pixels.width * pixels.height <= 2000000 || visibleRect.isEmpty) {
      return const SizedBox.shrink();
    }
    final clip = visibleRect.intersect(Offset.zero & displaySize);
    if (clip.isEmpty) return const SizedBox.shrink();
    final sx = pixels.width / displaySize.width, sy = pixels.height / displaySize.height;
    final firstX = (clip.left * sx / tileSide).floor();
    final firstY = (clip.top * sy / tileSide).floor();
    final lastX = (clip.right * sx / tileSide).ceil();
    final lastY = (clip.bottom * sy / tileSide).ceil();
    return Stack(children: [
      for (var y = firstY; y < lastY; y++)
        for (var x = firstX; x < lastX; x++)
          _positionTile(x, y, pixels, sx, sy),
    ]);
  }

  Widget _positionTile(int x, int y, Size pixels, double sx, double sy) {
    final bounds = Rect.fromLTRB((x * tileSide).toDouble(), (y * tileSide).toDouble(),
      math.min((x + 1) * tileSide.toDouble(), pixels.width),
      math.min((y + 1) * tileSide.toDouble(), pixels.height));
    final padded = bounds.inflate(1).intersect(Offset.zero & pixels);
    final region = Rect.fromLTRB(padded.left / pixels.width, padded.top / pixels.height,
      padded.right / pixels.width, padded.bottom / pixels.height);
    return Positioned(key: ValueKey((page, scale, x, y)),
      left: bounds.left / sx, top: bounds.top / sy,
      width: bounds.width / sx, height: bounds.height / sy,
      child: ClipRect(child: Stack(clipBehavior: Clip.none, children: [
        Positioned(left: (padded.left - bounds.left) / sx, top: (padded.top - bounds.top) / sy,
          width: padded.width / sx, height: padded.height / sy,
          child: _PageTile(renders: renders, page: page, scale: scale, region: region)),
      ])));
  }
}

class _PageTile extends StatefulWidget {
  const _PageTile({required this.renders, required this.page,
    required this.scale, required this.region});
  final RenderService renders;
  final int page;
  final double scale;
  final Rect region;
  @override
  State<_PageTile> createState() => _PageTileState();
}

class _PageTileState extends State<_PageTile> {
  RenderTicket? _ticket;
  ui.Image? _image;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void didUpdateWidget(_PageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.renders != widget.renders || oldWidget.page != widget.page ||
        oldWidget.scale != widget.scale || oldWidget.region != widget.region) _load();
  }

  Future<void> _load() async {
    _ticket?.cancel();
    final ticket = widget.renders.requestTile(widget.page, widget.scale, widget.region);
    _ticket = ticket;
    try {
      final image = await ticket.result;
      if (!mounted || ticket != _ticket) { image?.dispose(); return; }
      if (image == null) return;
      final old = _image;
      setState(() => _image = image);
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    } catch (_) {
      // The whole-page preview remains available if a tile cannot render.
    }
  }

  @override
  void dispose() { _ticket?.cancel(); _image?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _image == null ? const SizedBox.shrink() :
    RawImage(image: _image, fit: BoxFit.fill, filterQuality: FilterQuality.low);
}
