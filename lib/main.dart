import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'app/app.dart';
import 'features/document/local_repository.dart';
import 'features/pdf_viewer/pdfrx_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await PdfrxEngine.initialize();
    final support = await getApplicationSupportDirectory();
    final repository = LocalRepository(Directory(p.join(support.path, 'documents')));
    runApp(PapertrailApp(repository: repository, engine: PdfrxEngine()));
  } catch (error, stack) {
    debugPrint('Startup failed: $error\n$stack');
    runApp(MaterialApp(home: Scaffold(body: Center(child: Padding(
      padding: const EdgeInsets.all(32), child: SelectableText(
        'Papertrail could not start.\n\n$error\n\nCheck that the application data folder is writable and the PDF engine is installed.'))))));
  }
}
