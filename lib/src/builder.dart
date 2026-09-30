import 'dart:async';
import 'dart:io';

import 'package:build/build.dart';
import 'package:path/path.dart' as p;

/// A builder that invokes the `flatc` FlatBuffers compiler to generate Dart
/// files from `.fbs` schema files.
class FlatcBuilder implements Builder {
  /// The directory containing input `.fbs` schema files.
  final String inputDir;

  /// The directory where generated `.g.dart` files will be written.
  final String outputDir;

  /// Path to the `flatc` executable.
  final String flatcPath;

  /// Additional command-line arguments to pass to `flatc`.
  final List<String> extraArgs;

  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments,
  )
  _runProcess;

  FlatcBuilder({
    this.inputDir = 'schemas',
    this.outputDir = 'lib/schemas',
    this.flatcPath = 'flatc',
    this.extraArgs = const [],
    Future<ProcessResult> Function(String executable, List<String> arguments)?
    runProcess,
  }) : _runProcess = runProcess ?? Process.run;

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final outputs = buildStep.allowedOutputs.toList();
    if (outputs.isEmpty) {
      return;
    }

    final inputId = buildStep.inputId;
    final tempDir = await Directory.systemTemp.createTemp('flatc_builder_');

    try {
      String inputFilePath;
      final diskFile = File(inputId.path);
      if (await diskFile.exists()) {
        inputFilePath = diskFile.path;
      } else {
        final inputContent = await buildStep.readAsString(inputId);
        final tempInput = File(p.join(tempDir.path, p.basename(inputId.path)));
        await tempInput.writeAsString(inputContent);
        inputFilePath = tempInput.path;
      }

      final args = <String>[
        '--dart',
        '-o',
        tempDir.path,
        ...extraArgs,
        inputFilePath,
      ];

      ProcessResult result;
      try {
        result = await _runProcess(flatcPath, args);
      } on ProcessException catch (e) {
        log.severe(
          'Failed to execute flatc at "$flatcPath". Please ensure FlatBuffers '
          'compiler (flatc) is installed and available in PATH or configure '
          '"flatc_path" in build.yaml.\n'
          'Error: ${e.message}',
        );
        return;
      } catch (e) {
        log.severe('Unexpected error running flatc ($flatcPath): $e');
        return;
      }

      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        final stdout = result.stdout.toString().trim();
        final output = [
          if (stdout.isNotEmpty) stdout,
          if (stderr.isNotEmpty) stderr,
        ].join('\n');
        log.severe(
          'flatc failed with exit code ${result.exitCode} for ${inputId.path}'
          '${output.isNotEmpty ? ':\n$output' : ''}',
        );
        return;
      }

      final dartFiles = await tempDir
          .list(recursive: true)
          .where((entity) => entity is File && entity.path.endsWith('.dart'))
          .cast<File>()
          .toList();

      if (dartFiles.isEmpty) {
        log.severe(
          'flatc succeeded with exit code 0 but generated no .dart files for ${inputId.path}',
        );
        return;
      }

      final baseName = p.basenameWithoutExtension(inputId.path).toLowerCase();
      File? targetFile;

      if (dartFiles.length == 1) {
        targetFile = dartFiles.first;
      } else {
        for (final file in dartFiles) {
          final fileName = p.basenameWithoutExtension(file.path).toLowerCase();
          if (fileName == '${baseName}_generated' || fileName == baseName) {
            targetFile = file;
            break;
          }
        }
        targetFile ??= dartFiles.firstWhere(
          (f) => p
              .basenameWithoutExtension(f.path)
              .toLowerCase()
              .contains(baseName),
          orElse: () => dartFiles.first,
        );
      }

      final generatedContent = await targetFile.readAsString();
      final outputId = outputs.first;
      await buildStep.writeAsString(outputId, generatedContent);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true).catchError((_) => tempDir);
      }
    }
  }

  @override
  Map<String, List<String>> get buildExtensions {
    final cleanIn = _normalizeDir(inputDir);
    final cleanOut = _normalizeDir(outputDir);
    final inPattern = cleanIn.isEmpty ? r'^{{}}.fbs' : '^$cleanIn/{{}}.fbs';
    final outPattern = cleanOut.isEmpty
        ? r'{{}}.g.dart'
        : '$cleanOut/{{}}.g.dart';
    return {
      inPattern: [outPattern],
    };
  }

  static String _normalizeDir(String dir) {
    var clean = p.posix.normalize(dir.replaceAll(r'\', '/'));
    if (clean == '.' || clean == '/') return '';
    clean = clean.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    return clean;
  }
}

/// Factory function to create a [FlatcBuilder] from [BuilderOptions].
Builder flatcBuilder(BuilderOptions options) {
  final inputDir = options.config['input_dir'] as String? ?? 'schemas';
  final outputDir = options.config['output_dir'] as String? ?? 'lib/schemas';
  final flatcPath = options.config['flatc_path'] as String? ?? 'flatc';
  final extraArgs =
      (options.config['extra_args'] as List?)
          ?.map((e) => e.toString())
          .toList() ??
      const <String>[];

  return FlatcBuilder(
    inputDir: inputDir,
    outputDir: outputDir,
    flatcPath: flatcPath,
    extraArgs: extraArgs,
  );
}
