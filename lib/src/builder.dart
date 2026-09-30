import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Signature of the function used to run `flatc`, compatible with
/// [Process.run].
typedef RunProcess =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

/// Signature of the function checking whether a directory (relative to the
/// package root) contains `.fbs` files on disk.
typedef HasSchemasOnDisk = bool Function(String dir);

/// A builder that invokes the `flatc` FlatBuffers compiler to generate Dart
/// files from `.fbs` schema files.
///
/// Schemas (and everything they `include`) are read through the [BuildStep],
/// so `build_runner` tracks included files as dependencies, and staged into a
/// temporary directory before `flatc` runs.
///
/// A schema that only `include`s other schemas (and declares no types)
/// produces a barrel file exporting the outputs of its direct includes.
class FlatcBuilder implements Builder {
  /// The directory containing input `.fbs` schema files.
  final String inputDir;

  /// The directory where generated `.g.dart` files will be written.
  final String outputDir;

  /// Path to the `flatc` executable.
  final String flatcPath;

  /// Additional command-line arguments to pass to `flatc`.
  final List<String> extraArgs;

  final RunProcess _runProcess;

  final HasSchemasOnDisk _hasSchemasOnDisk;

  FlatcBuilder({
    this.inputDir = 'schemas',
    this.outputDir = 'lib/schemas',
    this.flatcPath = 'flatc',
    this.extraArgs = const [],
    RunProcess? runProcess,
    HasSchemasOnDisk? hasSchemasOnDisk,
  }) : _runProcess = runProcess ?? Process.run,
       _hasSchemasOnDisk = hasSchemasOnDisk ?? _defaultHasSchemasOnDisk;

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    if (buildStep.inputId.path == _packageInput) {
      await _checkSources(buildStep);
      return;
    }

    final outputs = buildStep.allowedOutputs.toList();
    if (outputs.isEmpty) {
      return;
    }

    final inputId = buildStep.inputId;
    final outputId = outputs.first;
    final tempDir = await Directory.systemTemp.createTemp('flatc_builder_');

    try {
      final srcDir = p.join(tempDir.path, 'src');
      final outDir = p.join(tempDir.path, 'out');
      await Directory(outDir).create(recursive: true);

      final schemas = await _stageSchemas(buildStep, srcDir);
      if (schemas == null) {
        return;
      }

      final args = <String>[
        '--dart',
        '-o',
        outDir,
        '-I',
        p.joinAll([srcDir, ...p.posix.split(_inDir)]),
        '-I',
        srcDir,
        ...extraArgs,
        _stagedPath(srcDir, inputId.path),
      ];

      ProcessResult result;
      try {
        result = await _runProcess(flatcPath, args, workingDirectory: srcDir);
      } on ProcessException catch (e) {
        log.severe(
          'Failed to execute flatc at "$flatcPath". Please ensure FlatBuffers '
          'compiler (flatc) is installed and available in PATH or configure '
          '"flatc_path" in build.yaml.\n'
          'Error: ${e.message}',
        );
        return;
      } catch (e, st) {
        log.severe('Unexpected error running flatc ($flatcPath)', e, st);
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

      final dartFiles = await Directory(outDir)
          .list(recursive: true)
          .where((entity) => entity is File && entity.path.endsWith('.dart'))
          .cast<File>()
          .toList();

      if (dartFiles.isEmpty) {
        if (schemas.direct.isEmpty) {
          log.severe(
            'flatc succeeded with exit code 0 but generated no .dart files for '
            '${inputId.path}: the schema declares no types and has no includes.',
          );
          return;
        }
        final barrel = _barrelFor(inputId, outputId, schemas.direct);
        if (barrel != null) {
          await buildStep.writeAsString(outputId, barrel);
        }
        return;
      }

      if (dartFiles.length > 1) {
        final names = dartFiles.map((f) => p.basename(f.path)).toList()..sort();
        log.severe(
          'Schema ${inputId.path} declares multiple namespaces '
          '(flatc generated ${names.join(', ')}); split it into one namespace '
          'per file and use `include` to share types.',
        );
        return;
      }

      final generated = await dartFiles.single.readAsString();
      final rewritten = _rewriteImports(
        generated,
        inputId,
        outputId,
        schemas.staged,
      );
      if (rewritten == null) {
        return;
      }
      await buildStep.writeAsString(outputId, rewritten);
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true).catchError((_) => tempDir);
      }
    }
  }

  /// Reads the primary input and all of its transitive includes through
  /// [buildStep] and writes them under [srcDir], preserving the package
  /// layout.
  ///
  /// Returns the package-relative paths of every staged schema (primary input
  /// first) and of the primary input's direct includes (in source order), or
  /// `null` when an include could not be resolved.
  Future<({List<String> staged, List<String> direct})?> _stageSchemas(
    BuildStep buildStep,
    String srcDir,
  ) async {
    final inputId = buildStep.inputId;
    final staged = <String>[];
    final direct = <String>[];
    final visited = <String>{inputId.path};
    final queue = Queue<String>()..add(inputId.path);

    while (queue.isNotEmpty) {
      final path = queue.removeFirst();
      final content = await buildStep.readAsString(
        AssetId(inputId.package, path),
      );
      final file = File(_stagedPath(srcDir, path));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      staged.add(path);

      for (final include in parseIncludes(content)) {
        final candidates = _includeCandidates(path, include);
        String? resolved;
        for (final candidate in candidates) {
          if (await buildStep.canRead(AssetId(inputId.package, candidate))) {
            resolved = candidate;
            break;
          }
        }
        if (resolved == null) {
          log.severe(
            'Unable to resolve include "$include" in $path. Tried: '
            '${candidates.join(', ')}. Make sure the file exists and is part '
            'of the build sources.',
          );
          return null;
        }
        if (path == inputId.path && !direct.contains(resolved)) {
          direct.add(resolved);
        }
        if (visited.add(resolved)) {
          queue.add(resolved);
        }
      }
    }
    return (staged: staged, direct: direct);
  }

  /// Renders a barrel file exporting the outputs of [includes], for a schema
  /// that only includes other schemas.
  ///
  /// Returns `null` (after logging) when an include has no output.
  String? _barrelFor(AssetId inputId, AssetId outputId, List<String> includes) {
    final fromDir = p.posix.dirname(outputId.path);
    final out = StringBuffer(
      '// Generated by flat_buffers_generator from ${inputId.path}. '
      'Do not edit.\n\n',
    );
    for (final include in includes) {
      final target = outputPathFor(include);
      if (target == null) {
        log.severe(_outsideInputDirMessage(include, inputId.path));
        return null;
      }
      out.writeln("export '${p.posix.relative(target, from: fromDir)}';");
    }
    return out.toString();
  }

  /// Warns when [inputDir] holds `.fbs` files on disk that aren't build
  /// sources, in which case the builder never runs on them.
  Future<void> _checkSources(BuildStep buildStep) async {
    if (_inDir.isEmpty) return;
    final noSources = await buildStep
        .findAssets(Glob('$_inDir/**$_schemaExtension'))
        .isEmpty;
    if (!noSources || !_hasSchemasOnDisk(_inDir)) return;
    log.warning(
      'Found $_schemaExtension files in "$_inDir/" but none of them are build '
      'sources, so no Dart code is generated. Add this to your build.yaml:\n'
      '  additional_public_assets:\n'
      '    - "$_inDir/**"\n'
      'See the flat_buffers_generator README for details.',
    );
  }

  /// Candidate package-relative paths for `include "[include]";` found in
  /// [from], in the order flatc searches them: relative to the including
  /// file, then to [inputDir], then to the package root.
  List<String> _includeCandidates(String from, String include) {
    final name = include.replaceAll(r'\', '/');
    final candidates = <String>[
      p.posix.normalize(p.posix.join(p.posix.dirname(from), name)),
      if (_inDir.isNotEmpty) p.posix.normalize(p.posix.join(_inDir, name)),
      p.posix.normalize(name),
    ];
    return candidates
        .where((c) => !c.startsWith('../') && c != '..')
        .toSet()
        .toList();
  }

  /// Rewrites flatc's `import './NAME_generated.dart'` directives so they
  /// point to the `.g.dart` outputs of the included schemas.
  ///
  /// Returns `null` (after logging) when an import cannot be mapped.
  String? _rewriteImports(
    String content,
    AssetId inputId,
    AssetId outputId,
    List<String> staged,
  ) {
    final includes = staged.where((s) => s != inputId.path).toList();
    final fromDir = p.posix.dirname(outputId.path);
    String? error;

    final result = content.replaceAllMapped(_generatedImport, (match) {
      if (error != null) return match[0]!;
      final quote = match[1]!;
      final name = match[2]!;

      var bestLength = -1;
      final best = <String>[];
      for (final include in includes) {
        final base = p.posix.basenameWithoutExtension(include);
        if (name != base && !name.startsWith('${base}_')) continue;
        if (base.length > bestLength) {
          bestLength = base.length;
          best
            ..clear()
            ..add(include);
        } else if (base.length == bestLength) {
          best.add(include);
        }
      }

      if (best.isEmpty) {
        error =
            'Cannot map import "./${name}_generated.dart" generated for '
            '${inputId.path} to an included schema.';
        return match[0]!;
      }
      if (best.length > 1) {
        error =
            'Import "./${name}_generated.dart" generated for ${inputId.path} '
            'is ambiguous: included schemas ${best.join(', ')} share the same '
            'file name. Rename one of them.';
        return match[0]!;
      }
      final target = outputPathFor(best.single);
      if (target == null) {
        error = _outsideInputDirMessage(best.single, inputId.path);
        return match[0]!;
      }
      final uri = p.posix.relative(target, from: fromDir);
      return 'import $quote$uri$quote';
    });

    if (error != null) {
      log.severe(error);
      return null;
    }
    return result;
  }

  String _outsideInputDirMessage(String include, String from) =>
      'Included schema $include (from $from) is outside input_dir '
      '"$inputDir", so no Dart file is generated for it. Move it under '
      '"$inputDir".';

  /// Maps a package-relative schema path under [inputDir] to the path of its
  /// generated Dart file, or `null` when [schemaPath] is outside [inputDir].
  ///
  /// This is the concrete form of the [buildExtensions] mapping.
  String? outputPathFor(String schemaPath) {
    final path = p.posix.normalize(schemaPath);
    if (!path.endsWith(_schemaExtension)) return null;
    String rel;
    if (_inDir.isEmpty) {
      rel = path;
    } else if (p.posix.isWithin(_inDir, path)) {
      rel = p.posix.relative(path, from: _inDir);
    } else {
      return null;
    }
    rel = rel.substring(0, rel.length - _schemaExtension.length);
    return _outDir.isEmpty
        ? '$rel$_outputExtension'
        : '$_outDir/$rel$_outputExtension';
  }

  @override
  Map<String, List<String>> get buildExtensions {
    final inPattern = _inDir.isEmpty
        ? '^{{}}$_schemaExtension'
        : '^$_inDir/{{}}$_schemaExtension';
    final outPattern = _outDir.isEmpty
        ? '{{}}$_outputExtension'
        : '$_outDir/{{}}$_outputExtension';
    return {
      inPattern: [outPattern],
      // Placeholder, never written: runs the builder once per package to
      // check that schemas are build sources.
      _packageInput: [
        _outDir.isEmpty ? _packageCheckOutput : '$_outDir/$_packageCheckOutput',
      ],
    };
  }

  String get _inDir => _normalizeDir(inputDir);

  String get _outDir => _normalizeDir(outputDir);

  static const _schemaExtension = '.fbs';
  static const _outputExtension = '.g.dart';
  static const _packageInput = r'$package$';
  static const _packageCheckOutput = '.flat_buffers_generator';

  static bool _defaultHasSchemasOnDisk(String dir) {
    final directory = Directory(dir);
    return directory.existsSync() &&
        directory
            .listSync(recursive: true)
            .any((e) => e is File && e.path.endsWith(_schemaExtension));
  }

  static final _generatedImport = RegExp(
    r'''import\s+(['"])\./([^'"]+)_generated\.dart\1''',
  );

  static String _stagedPath(String srcDir, String assetPath) =>
      p.joinAll([srcDir, ...p.posix.split(assetPath)]);

  static String _normalizeDir(String dir) {
    var clean = p.posix.normalize(dir.replaceAll(r'\', '/'));
    if (clean == '.' || clean == '/') return '';
    clean = clean.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    return clean;
  }
}

/// Returns the file names referenced by `include "…";` directives in a
/// FlatBuffers [schema], ignoring comments.
List<String> parseIncludes(String schema) {
  final stripped = _stripComments(schema);
  return [
    for (final match in _includeDirective.allMatches(stripped)) match[1]!,
  ];
}

final _includeDirective = RegExp(r'(?:^|[\s;])include\s+"([^"]+)"\s*;');

/// Removes `//` and `/* */` comments while leaving string literals intact.
String _stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (c == '"') {
      final end = _endOfString(source, i);
      out.write(source.substring(i, end));
      i = end;
    } else if (c == '/' && next == '/') {
      final end = source.indexOf('\n', i);
      i = end == -1 ? source.length : end;
    } else if (c == '/' && next == '*') {
      final end = source.indexOf('*/', i + 2);
      i = end == -1 ? source.length : end + 2;
      out.write(' ');
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

int _endOfString(String source, int start) {
  var i = start + 1;
  while (i < source.length) {
    final c = source[i];
    if (c == r'\') {
      i += 2;
    } else if (c == '"') {
      return i + 1;
    } else if (c == '\n') {
      return i;
    } else {
      i++;
    }
  }
  return source.length;
}

/// `extra_args` that conflict with how the builder drives `flatc`.
const _forbiddenArgs = {
  '-o': 'the builder chooses the output directory',
  '-I': 'includes are resolved from the package sources automatically',
  '--gen-all': 'each schema is generated separately',
  '--filename-suffix': 'generated imports rely on the default suffix',
  '--filename-ext': 'the builder always writes .g.dart files',
};

/// Non-Dart generator flags accepted by flatc.
const _languageArgs = {
  '-b', '--binary', '-t', '--json', '-c', '--cpp', '-j', '--java', //
  '--kotlin', '--kotlin-kmp', '-n', '--csharp', '-g', '--go', //
  '-p', '--python', '-r', '--rust', '-s', '--js', '-T', '--ts', //
  '--php', '--swift', '--nim', '-l', '--lua', '--lobster', //
  '--jsonschema', '--grpc', '--proto', '--conform', '--annotate', //
};

/// Factory function to create a [FlatcBuilder] from [BuilderOptions].
///
/// Throws an [ArgumentError] when the options conflict with the builder.
Builder flatcBuilder(BuilderOptions options) {
  final inputDir = options.config['input_dir'] as String? ?? 'schemas';
  final outputDir = options.config['output_dir'] as String? ?? 'lib/schemas';
  final flatcPath = options.config['flatc_path'] as String? ?? 'flatc';
  final extraArgs =
      (options.config['extra_args'] as List?)
          ?.map((e) => e.toString())
          .toList() ??
      const <String>[];

  for (final arg in extraArgs) {
    final flag = arg.split('=').first;
    final reason = _forbiddenArgs[flag];
    if (reason != null) {
      throw ArgumentError.value(
        extraArgs,
        'extra_args',
        '"$arg" is not supported: $reason',
      );
    }
    if (_languageArgs.contains(flag)) {
      throw ArgumentError.value(
        extraArgs,
        'extra_args',
        '"$arg" is not supported: flat_buffers_generator only generates Dart',
      );
    }
  }

  if (FlatcBuilder._normalizeDir(inputDir) ==
      FlatcBuilder._normalizeDir(outputDir)) {
    throw ArgumentError.value(
      outputDir,
      'output_dir',
      'must be different from input_dir',
    );
  }

  return FlatcBuilder(
    inputDir: inputDir,
    outputDir: outputDir,
    flatcPath: flatcPath,
    extraArgs: extraArgs,
  );
}
