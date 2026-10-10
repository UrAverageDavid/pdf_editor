import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../features/annotations/editor_controller.dart';
import '../features/document/app_document.dart';
import '../features/document/local_repository.dart';
import '../features/pdf_viewer/pdf_engine.dart';
import '../features/pdf_viewer/render_service.dart';
import 'editor_screen.dart';
import 'library_screen.dart';

const paper = Color(0xfff7f7f2);
const accent = Color(0xff2947c7);
const ink = Color(0xff222b35);

class PapertrailApp extends StatelessWidget {
  const PapertrailApp({super.key, required this.repository, required this.engine});
  final LocalRepository repository;
  final PdfEngine engine;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Papertrail', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, surface: paper),
      textTheme: ThemeData.light().textTheme.apply(bodyColor: ink, displayColor: ink),
      dividerColor: const Color(0xffdddfd7),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
        minimumSize: const Size(44, 44), foregroundColor: ink)),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        backgroundColor: accent, foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    ),
    home: Workspace(repository: repository, engine: engine),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.repository, required this.engine});
  final LocalRepository repository;
  final PdfEngine engine;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  final _editorKey = GlobalKey<EditorScreenState>();
  EditorController? _editor;
  RenderService? _renders;
  List<AppDocument> _recent = [];
  bool _busy = false;
  bool _ready = false;
  String? _libraryError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadRecent());
  }

  Future<void> _loadRecent() async {
    try {
      final documents = await widget.repository.recent();
      if (mounted) setState(() { _recent = documents; _libraryError = null; _ready = true; });
    } catch (error) {
      if (mounted) setState(() { _libraryError = '$error'; _ready = true; });
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text),
      behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 7)));
  }

  Future<void> _save() async {
    _editorKey.currentState?.finishInput();
    await _editor?.flush();
  }

  Future<void> _pick() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _save();
      final file = await openFile(acceptedTypeGroups: [const XTypeGroup(
        label: 'PDF documents', extensions: ['pdf'], mimeTypes: ['application/pdf'],
        uniformTypeIdentifiers: ['com.adobe.pdf'])]);
      if (file == null) return;
      final id = await widget.repository.importPdf(file);
      await _open(id, name: file.name, originalPath: file.path);
    } catch (error, stack) {
      debugPrint('Open failed: $error\n$stack');
      _message('Could not open this PDF. Your current notes are still available. $error');
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _sample() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await rootBundle.load('assets/welcome.pdf');
      final file = XFile.fromData(bytes.buffer.asUint8List(), name: 'A little room to think.pdf',
        mimeType: 'application/pdf');
      final id = await widget.repository.importPdf(file);
      await _open(id, name: 'A little room to think.pdf', originalPath: 'Bundled sample');
    } catch (error) { _message('Could not open the sample. $error'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _openRecent(AppDocument document) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _save();
      await widget.repository.verifySource(document.id);
      await _open(document.id);
    } catch (error) { _message('Could not reopen the document. Notes were preserved. $error'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _open(String id, {String? name, String? originalPath}) async {
    final loaded = await widget.repository.load(id);
    final sourcePath = widget.repository.pdfPath(id);
    final handle = await widget.engine.open(sourcePath);
    final AppDocument document;
    try {
      document = loaded?.document ?? AppDocument(id: id,
        displayName: name ?? 'Untitled PDF', sourcePath: sourcePath,
        originalPath: originalPath ?? '', pageCount: handle.pageCount, modifiedAt: DateTime.now());
      if (document.pageCount != handle.pageCount) {
        throw const FormatException('Page count changed. Existing annotations were preserved.');
      }
      // Commit the initial metadata before making this document editable.
      document.modifiedAt = DateTime.now();
      await widget.repository.save(document.toJson());
    } catch (_) { await handle.close(); rethrow; }
    if (!mounted) { await handle.close(); return; }
    final oldEditor = _editor;
    final oldRenders = _renders;
    // Unmount the old view before disposing its painters and listeners.
    setState(() { _editor = null; _renders = null; });
    await WidgetsBinding.instance.endOfFrame;
    oldEditor?.dispose();
    await oldRenders?.close();
    if (!mounted) { await handle.close(); return; }
    setState(() {
      _editor = EditorController(document, widget.repository);
      _renders = RenderService(handle);
    });
    if (loaded?.recovered ?? false) {
      _message('Recovered the last readable save. A newer damaged save was kept for recovery.');
    }
  }

  Future<void> _back() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _save();
      final editor = _editor;
      final renders = _renders;
      setState(() { _editor = null; _renders = null; });
      await WidgetsBinding.instance.endOfFrame;
      editor?.dispose();
      await renders?.close();
      await _loadRecent();
    } catch (error) { _message('Could not save. Keep this document open and retry. $error'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _backup() async {
    if (_editor == null || _busy) return;
    _editorKey.currentState?.finishInput();
    setState(() => _busy = true);
    try {
      final snapshot = _editor!.document.toJson();
      final destination = await getSaveLocation(suggestedName:
          '${p.basenameWithoutExtension(_editor!.document.displayName)}.papertrail.json',
        acceptedTypeGroups: [const XTypeGroup(label: 'Annotation backup', extensions: ['json'])]);
      if (destination == null) return;
      final output = p.normalize(p.absolute(destination.path));
      final protected = [_editor!.document.sourcePath, _editor!.document.originalPath];
      if (protected.any((path) => p.equals(p.normalize(p.absolute(path)), output)) ||
          p.isWithin(widget.repository.root.path, output)) {
        throw const FileSystemException('Choose a backup location outside the document library.');
      }
      if (await File(destination.path).exists()) {
        throw const FileSystemException('Choose a new filename so no existing file is replaced.');
      }
      await XFile.fromData(utf8.encode(jsonEncode(snapshot)), mimeType: 'application/json')
          .saveTo(destination.path);
      _message('Annotation backup saved. This is a notes file, not an annotated PDF.');
    } catch (error) { _message('Backup could not be saved. $error'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_save().catchError((Object error) { _message('Autosave failed. $error'); }));
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    try { await _save(); return AppExitResponse.exit; }
    catch (error) { _message('Could not save notes. Close cancelled; please retry. $error');
      return AppExitResponse.cancel; }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editor?.dispose();
    final renders = _renders;
    if (renders != null) unawaited(renders.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _editor == null,
    onPopInvokedWithResult: (didPop, result) { if (!didPop) unawaited(_back()); },
    child: Scaffold(body: SafeArea(child: Stack(children: [
      if (_editor != null && _renders != null)
        EditorScreen(key: _editorKey, editor: _editor!, renders: _renders!,
          onOpen: _pick, onBack: _back,
          onBackup: Platform.isWindows || Platform.isMacOS || Platform.isLinux ? _backup : null)
      else LibraryScreen(documents: _recent, loading: !_ready,
        error: _libraryError, onOpen: _pick, onSample: _sample,
        onRecent: _openRecent, onRetry: _loadRecent),
      if (_busy) Positioned.fill(child: ColoredBox(color: paper.withValues(alpha: .76),
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(), SizedBox(height: 20), Text('Preparing your document…'),
        ])))),
    ]))),
  );
}
