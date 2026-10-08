import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'render_service.dart';

class PageImage extends StatefulWidget {
  const PageImage({super.key, required this.renders, required this.page,
    required this.scale, this.priority = 1});
  final RenderService renders;
  final int page;
  final double scale;
  final int priority;
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
    if (oldWidget.page != widget.page || oldWidget.renders != widget.renders ||
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
