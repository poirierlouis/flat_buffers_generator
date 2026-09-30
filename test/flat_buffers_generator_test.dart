import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:flat_buffers_generator/flat_buffers_generator.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('FlatcBuilder options & buildExtensions', () {
    test('defaults', () {
      final builder = FlatcBuilder();
      expect(builder.inputDir, equals('schemas'));
      expect(builder.outputDir, equals('lib/schemas'));
      expect(builder.flatcPath, equals('flatc'));
      expect(builder.extraArgs, isEmpty);
      expect(
        builder.buildExtensions,
        equals({
          r'^schemas/{{}}.fbs': ['lib/schemas/{{}}.g.dart'],
        }),
      );
    });

    test('custom options and normalized extensions', () {
      final builder = FlatcBuilder(
        inputDir: r'custom\fbs\',
        outputDir: '/generated/flatbuffers/',
        flatcPath: '/usr/local/bin/flatc',
        extraArgs: ['--gen-mutable', '--raw-binary'],
      );
      expect(builder.inputDir, equals(r'custom\fbs\'));
      expect(builder.outputDir, equals('/generated/flatbuffers/'));
      expect(builder.flatcPath, equals('/usr/local/bin/flatc'));
      expect(builder.extraArgs, equals(['--gen-mutable', '--raw-binary']));
      expect(
        builder.buildExtensions,
        equals({
          r'^custom/fbs/{{}}.fbs': ['generated/flatbuffers/{{}}.g.dart'],
        }),
      );
    });

    test('root/empty input and output directories', () {
      final builder = FlatcBuilder(
        inputDir: '.',
        outputDir: '',
      );
      expect(
        builder.buildExtensions,
        equals({
          r'^{{}}.fbs': ['{{}}.g.dart'],
        }),
      );
    });

    test('flatcBuilder factory with default BuilderOptions', () {
      final builder = flatcBuilder(BuilderOptions.empty) as FlatcBuilder;
      expect(builder.inputDir, equals('schemas'));
      expect(builder.outputDir, equals('lib/schemas'));
      expect(builder.flatcPath, equals('flatc'));
      expect(builder.extraArgs, isEmpty);
      expect(
        builder.buildExtensions,
        equals({
          r'^schemas/{{}}.fbs': ['lib/schemas/{{}}.g.dart'],
        }),
      );
    });

    test('flatcBuilder factory with custom BuilderOptions', () {
      final options = BuilderOptions({
        'input_dir': 'fbs_schemas',
        'output_dir': 'lib/models',
        'flatc_path': r'C:\tools\flatc.exe',
        'extra_args': ['--gen-object-api', '--scoped-enums'],
      });
      final builder = flatcBuilder(options) as FlatcBuilder;
      expect(builder.inputDir, equals('fbs_schemas'));
      expect(builder.outputDir, equals('lib/models'));
      expect(builder.flatcPath, equals(r'C:\tools\flatc.exe'));
      expect(
        builder.extraArgs,
        equals(['--gen-object-api', '--scoped-enums']),
      );
      expect(
        builder.buildExtensions,
        equals({
          r'^fbs_schemas/{{}}.fbs': ['lib/models/{{}}.g.dart'],
        }),
      );
    });
  });

  group('Hermetic testBuilder execution', () {
    test('successful code generation for default paths', () async {
      late List<String> capturedArgs;
      late String capturedExecutable;

      final builder = FlatcBuilder(
        extraArgs: ['--gen-mutable'],
        runProcess: (executable, args) async {
          capturedExecutable = executable;
          capturedArgs = args;

          final outputDirIndex = args.indexOf('-o') + 1;
          final outputDirPath = args[outputDirIndex];

          final generatedFile =
              File(p.join(outputDirPath, 'user_generated.dart'));
          await generatedFile
              .writeAsString('// Generated FlatBuffer Dart code\nclass User {}');

          return ProcessResult(1234, 0, '', '');
        },
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs': 'table User { id: int; name: string; }',
        },
        outputs: {
          'my_pkg|lib/schemas/user.g.dart':
              '// Generated FlatBuffer Dart code\nclass User {}',
        },
      );

      expect(capturedExecutable, equals('flatc'));
      expect(capturedArgs, contains('--dart'));
      expect(capturedArgs, contains('--gen-mutable'));
    });

    test('successful code generation for custom paths and nested subdirectories', () async {
      final builder = FlatcBuilder(
        inputDir: 'custom_fbs',
        outputDir: 'lib/models',
        runProcess: (executable, args) async {
          final outputDirIndex = args.indexOf('-o') + 1;
          final outputDirPath = args[outputDirIndex];

          final generatedFile =
              File(p.join(outputDirPath, 'monster_generated.dart'));
          await generatedFile.writeAsString('class Monster {}');

          return ProcessResult(1234, 0, '', '');
        },
      );

      await testBuilder(
        builder,
        {
          'my_pkg|custom_fbs/game/monster.fbs': 'table Monster { hp: short; }',
        },
        outputs: {
          'my_pkg|lib/models/game/monster.g.dart': 'class Monster {}',
        },
      );
    });

    test('selects matching basename when multiple .dart files are generated', () async {
      final builder = FlatcBuilder(
        runProcess: (executable, args) async {
          final outputDirIndex = args.indexOf('-o') + 1;
          final outputDirPath = args[outputDirIndex];

          await File(p.join(outputDirPath, 'dependency_generated.dart'))
              .writeAsString('// Dependency');
          await File(p.join(outputDirPath, 'user_generated.dart'))
              .writeAsString('// User generated');

          return ProcessResult(1234, 0, '', '');
        },
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs': 'include "dependency.fbs"; table User {}',
        },
        outputs: {
          'my_pkg|lib/schemas/user.g.dart': '// User generated',
        },
      );
    });

    test('handles missing flatc executable (ProcessException) with severe log', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        flatcPath: 'non_existent_flatc',
        runProcess: (executable, args) async {
          throw ProcessException(executable, args, 'Executable not found', 2);
        },
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs': 'table User {}',
        },
        outputs: {},
        onLog: logs.add,
      );

      expect(
        logs.any((l) =>
            l.level >= Level.SEVERE &&
            l.message.contains('Failed to execute flatc at "non_existent_flatc"')),
        isTrue,
      );
    });

    test('handles non-zero exit code with severe log containing stderr/stdout', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        runProcess: (executable, args) async {
          return ProcessResult(
            1234,
            1,
            'stdout output',
            'error: unknown type `UnknownType` at line 12',
          );
        },
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/invalid.fbs': 'table Invalid { u: UnknownType; }',
        },
        outputs: {},
        onLog: logs.add,
      );

      expect(
        logs.any((l) =>
            l.level >= Level.SEVERE &&
            l.message.contains('flatc failed with exit code 1') &&
            l.message.contains('error: unknown type `UnknownType`')),
        isTrue,
      );
    });

    test('handles zero exit code when no .dart files were created', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        runProcess: (executable, args) async {
          return ProcessResult(1234, 0, '', '');
        },
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/empty.fbs': '// empty schema',
        },
        outputs: {},
        onLog: logs.add,
      );

      expect(
        logs.any((l) =>
            l.level >= Level.SEVERE &&
            l.message.contains('flatc succeeded with exit code 0 but generated no .dart files')),
        isTrue,
      );
    });
  });

  group('Real flatc binary compilation', () {
    test('compiles real schema file into Dart code when flatc is available', () async {
      ProcessResult? versionCheck;
      try {
        versionCheck = await Process.run('flatc', ['--version']);
      } catch (_) {
        // flatc not installed, skip real binary test
      }

      if (versionCheck == null || versionCheck.exitCode != 0) {
        // Skip test if flatc is not in environment
        return;
      }

      final builder = FlatcBuilder();

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/monster.fbs': '''
namespace MyGame.Sample;

table Monster {
  hp: short = 100;
  mana: short = 150;
  name: string;
}

root_type Monster;
''',
        },
        outputs: {
          'my_pkg|lib/schemas/monster.g.dart':
              decodedMatches(contains('Monster')),
        },
      );
    });
  });
}
