import 'package:flutter/material.dart';

import '../features/document/app_document.dart';
import 'app.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.documents, required this.loading,
    required this.error, required this.onOpen, required this.onSample,
    required this.onRecent, required this.onRetry});
  final List<AppDocument> documents;
  final bool loading;
  final String? error;
  final VoidCallback onOpen;
  final VoidCallback onSample;
  final void Function(AppDocument) onRecent;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final wide = constraints.maxWidth >= 850;
    return Row(children: [
      if (wide) Container(width: 232, decoration: const BoxDecoration(color: Color(0xffeeefe8),
        border: Border(right: BorderSide(color: Color(0xffdddfd7)))),
        padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Brand(), const SizedBox(height: 54),
          Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .65), borderRadius: BorderRadius.circular(10)),
            child: const Row(children: [Icon(Icons.auto_stories_outlined, size: 20),
              SizedBox(width: 12), Text('My documents', style: TextStyle(fontWeight: FontWeight.w600))])),
          const Spacer(),
          const Icon(Icons.lock_outline_rounded, size: 19, color: Color(0xff777e75)),
          const SizedBox(height: 10),
          const Text('A quiet place for your ideas.', style: TextStyle(fontSize: 13, height: 1.6)),
          const SizedBox(height: 6),
          const Text('Saved on this device.', style: TextStyle(fontSize: 12, color: Color(0xff777e75))),
          const SizedBox(height: 24), const Text('PROTOTYPE  /  0.1',
            style: TextStyle(fontSize: 10, letterSpacing: 1.6, color: Color(0xff777e75))),
        ])),
      Expanded(child: CustomScrollView(slivers: [
        SliverPadding(padding: EdgeInsets.fromLTRB(wide ? 56 : 24, 32, wide ? 56 : 24, 0),
          sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!wide) ...[const Brand(), const SizedBox(height: 38)],
            Row(children: [const Expanded(child: Text('YOUR WORKSPACE',
              style: TextStyle(fontSize: 11, letterSpacing: 2, color: Color(0xff737a70)))),
              Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(border: Border.all(color: const Color(0xffd9ded1)),
                  borderRadius: BorderRadius.circular(24)),
                child: const Row(children: [Icon(Icons.circle, color: Color(0xff718b56), size: 6),
                  SizedBox(width: 7), Text('Local & private', style: TextStyle(fontSize: 11))]))]),
            const SizedBox(height: 36),
            Text('A little room\nto think.', style: TextStyle(fontSize: wide ? 58 : 43,
              height: 1.08, letterSpacing: -2, fontWeight: FontWeight.w500)),
            const SizedBox(height: 20),
            const Text('Your PDFs. Your handwriting.\nPick up where your thoughts left off.',
              style: TextStyle(fontSize: 16, height: 1.7, color: Color(0xff72776f))),
            const SizedBox(height: 30),
            Wrap(spacing: 14, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.add, size: 20), label: const Text('Open a PDF')),
              TextButton.icon(onPressed: onSample, icon: const Icon(Icons.draw_outlined, size: 18),
                label: const Text('Try the practice document')),
            ]),
            const SizedBox(height: 48),
            const Divider(), const SizedBox(height: 26),
            Row(children: [const Expanded(child: Text('Recent documents',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600))),
              Text('${documents.length} ${documents.length == 1 ? 'document' : 'documents'}',
                style: const TextStyle(fontSize: 12, color: Color(0xff777e75)))]),
            const SizedBox(height: 18),
            if (loading) const LinearProgressIndicator(),
            if (error != null) Container(padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: const Color(0xfffff0dc), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('The document library needs attention.'), const SizedBox(height: 8),
                SelectableText(error!), TextButton(onPressed: onRetry, child: const Text('Try again')),
              ])),
            if (!loading && error == null && documents.isEmpty) Container(
              width: double.infinity, padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(border: Border.all(color: const Color(0xffdddfd7)),
                borderRadius: BorderRadius.circular(14)),
              child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.note_add_outlined, color: Color(0xff8a9383)), SizedBox(height: 16),
                Text('Your next idea starts with a page.', style: TextStyle(fontSize: 16)), SizedBox(height: 8),
                Text('Open a PDF or try the practice document.\nYour notes will be saved automatically.',
                  style: TextStyle(height: 1.6, color: Color(0xff777e75))),
              ])),
          ]))),
        SliverPadding(padding: EdgeInsets.fromLTRB(wide ? 56 : 24, 0, wide ? 56 : 24, 40),
          sliver: SliverList.builder(itemCount: documents.length, itemBuilder: (context, index) {
            final document = documents[index];
            final date = document.modifiedAt.toLocal();
            return Padding(padding: const EdgeInsets.only(bottom: 10), child: Material(
              color: Colors.white, shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xffe3e5dc))),
              child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                onTap: () => onRecent(document),
                leading: Container(width: 44, height: 52, decoration: BoxDecoration(
                  color: const Color(0xffedf0fb), borderRadius: BorderRadius.circular(7)),
                  child: const Icon(Icons.description_outlined, color: accent)),
                title: Text(document.displayName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                subtitle: Padding(padding: const EdgeInsets.only(top: 7), child: Text(
                  '${document.pageCount} pages  ·  ${document.strokeCount} strokes  ·  ${date.month}/${date.day}/${date.year}',
                  style: const TextStyle(fontSize: 12, color: Color(0xff777e75)))),
                trailing: const Icon(Icons.arrow_forward_rounded, size: 18),
              ),
            ));
          })),
      ])),
    ]);
  });
}

class Brand extends StatelessWidget {
  const Brand({super.key});
  @override
  Widget build(BuildContext context) => const Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.edit_note_rounded, color: accent, size: 31), SizedBox(width: 9),
    Text('papertrail', style: TextStyle(fontSize: 22, letterSpacing: -.8, fontWeight: FontWeight.w600)),
  ]);
}
