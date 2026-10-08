// Run with `dart tool/bootstrap.dart` after installing Flutter.
// Generate native runners with YOUR installed Flutter, without replacing code.
import 'dart:io';

Future<void> main() async {
  final root = Directory.current;
  if (!File('${root.path}/pubspec.yaml').existsSync()) {
    stderr.writeln('Run this script from the Papertrail project directory.');
    exitCode = 1;
    return;
  }
  final temp = await Directory.systemTemp.createTemp('papertrail-bootstrap-');
  try {
    final result = await Process.run('flutter', [
      'create', '--project-name', 'papertrail', '--org', 'dev.papertrail',
      '--platforms', 'windows,macos,ios,android', '--no-pub', '${temp.path}/app',
    ], runInShell: Platform.isWindows);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) { exitCode = result.exitCode; return; }
    for (final name in ['windows', 'macos', 'ios', 'android']) {
      final source = Directory('${temp.path}/app/$name');
      final destination = Directory('${root.path}/$name');
      if (!destination.existsSync()) await copyDirectory(source, destination);
    }
    final metadata = File('${root.path}/.metadata');
    if (!metadata.existsSync()) await File('${temp.path}/app/.metadata').copy(metadata.path);
    for (final name in ['DebugProfile', 'Release']) {
      final entitlements = File('${root.path}/macos/Runner/$name.entitlements');
      if (entitlements.existsSync()) {
        var text = await entitlements.readAsString();
        if (!text.contains('com.apple.security.files.user-selected.read-write')) {
          text = text.replaceFirst('</dict>',
              '\t<key>com.apple.security.files.user-selected.read-write</key>\n\t<true/>\n</dict>');
          await entitlements.writeAsString(text);
        }
      }
    }
    stdout.writeln('Native runners prepared. Resolving dependencies…');
    final get = await Process.start('flutter', ['pub', 'get'],
      workingDirectory: root.path, runInShell: Platform.isWindows,
      mode: ProcessStartMode.inheritStdio);
    exitCode = await get.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln('Flutter must be installed and available on PATH.\n$error');
    exitCode = 1;
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list()) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (entity is Directory) {
      await copyDirectory(entity, Directory('${destination.path}/$name'));
    } else if (entity is File) {
      await entity.copy('${destination.path}/$name');
    }
  }
}
