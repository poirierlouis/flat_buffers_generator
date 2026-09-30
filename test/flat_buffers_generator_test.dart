import 'dart:io';

import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:flat_buffers_generator/flat_buffers_generator.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Recorded invocation of a fake `flatc`.
class FlatcCall {
  final String executable;
  final List<String> args;
  final String workingDirectory;

  FlatcCall(this.executable, this.args, this.workingDirectory);

  /// Directory passed to `-o`.
  String get outputDir => args[args.indexOf('-o') + 1];

  /// Last argument: the staged primary schema.
  String get input => args.last;
}

/// Returns a fake `flatc` that writes [files] (name -> content) to the `-o`
/// directory, after asserting that every path in [expectStaged] (package
/// relative) was staged under the working directory.
///
/// When [primary] is set, any other input (e.g. an included schema, which is
/// also built on its own) gets an empty `<base>_generated.dart` instead.
RunProcess fakeFlatc(
  Map<String, String> files, {
  String? primary,
  List<String> expectStaged = const [],
  void Function(FlatcCall call)? onCall,
}) {
  return (executable, args, {workingDirectory}) async {
    expect(workingDirectory, isNotNull);
    final call = FlatcCall(executable, args, workingDirectory!);
    if (primary != null && p.basename(call.input) != primary) {
      final base = p.basenameWithoutExtension(call.input);
      await File(
        p.join(call.outputDir, '${base}_generated.dart'),
      ).writeAsString('');
      return ProcessResult(1234, 0, '', '');
    }
    onCall?.call(call);
    expect(File(call.input).existsSync(), isTrue, reason: call.input);
    expect(p.isWithin(workingDirectory, call.input), isTrue);
    for (final staged in expectStaged) {
      final file = File(
        p.joinAll([workingDirectory, ...p.posix.split(staged)]),
      );
      expect(file.existsSync(), isTrue, reason: '$staged should be staged');
    }
    for (final entry in files.entries) {
      await File(p.join(call.outputDir, entry.key)).writeAsString(entry.value);
    }
    return ProcessResult(1234, 0, '', '');
  };
}

bool _hasSevere(List<LogRecord> logs, String text) =>
    logs.any((l) => l.level >= Level.SEVERE && l.message.contains(text));

bool _flatcAvailable() {
  try {
    return Process.runSync('flatc', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

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
          r'$package$': ['lib/schemas/.flat_buffers_generator'],
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
          r'$package$': ['generated/flatbuffers/.flat_buffers_generator'],
        }),
      );
    });

    test('root/empty input and output directories', () {
      final builder = FlatcBuilder(inputDir: '.', outputDir: '');
      expect(
        builder.buildExtensions,
        equals({
          r'^{{}}.fbs': ['{{}}.g.dart'],
          r'$package$': ['.flat_buffers_generator'],
        }),
      );
    });

    test('outputPathFor matches buildExtensions', () {
      final builder = FlatcBuilder();
      expect(
        builder.outputPathFor('schemas/game/monster.fbs'),
        equals('lib/schemas/game/monster.g.dart'),
      );
      expect(builder.outputPathFor('other/monster.fbs'), isNull);
      expect(
        FlatcBuilder(inputDir: '', outputDir: 'gen').outputPathFor('a/b.fbs'),
        equals('gen/a/b.g.dart'),
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
          r'$package$': ['lib/schemas/.flat_buffers_generator'],
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
      expect(builder.extraArgs, equals(['--gen-object-api', '--scoped-enums']));
      expect(
        builder.buildExtensions,
        equals({
          r'^fbs_schemas/{{}}.fbs': ['lib/models/{{}}.g.dart'],
          r'$package$': ['lib/models/.flat_buffers_generator'],
        }),
      );
    });

    for (final arg in ['-o', '--gen-all', '--cpp', '-I', '--ts']) {
      test('flatcBuilder factory rejects "$arg" in extra_args', () {
        expect(
          () => flatcBuilder(
            BuilderOptions({
              'extra_args': ['--gen-mutable', arg],
            }),
          ),
          throwsArgumentError,
        );
      });
    }

    test('flatcBuilder factory rejects input_dir == output_dir', () {
      expect(
        () => flatcBuilder(
          const BuilderOptions({
            'input_dir': 'lib/fbs',
            'output_dir': 'lib/fbs/',
          }),
        ),
        throwsArgumentError,
      );
    });
  });

  group('parseIncludes', () {
    test('finds includes and ignores comments', () {
      expect(
        parseIncludes('''
// include "commented.fbs";
/* include "block.fbs"; */
include "a.fbs";
include "dir/b.fbs";  // trailing
attribute "url://not/a/comment";
namespace X;
'''),
        equals(['a.fbs', 'dir/b.fbs']),
      );
    });
  });

  group('Hermetic testBuilder execution', () {
    test('successful code generation for default paths', () async {
      late FlatcCall call;
      final builder = FlatcBuilder(
        extraArgs: ['--gen-mutable'],
        runProcess: fakeFlatc(
          {
            'user_generated.dart':
                '// Generated FlatBuffer Dart code\nclass User {}',
          },
          expectStaged: ['schemas/user.fbs'],
          onCall: (c) => call = c,
        ),
      );

      await testBuilder(
        builder,
        {'my_pkg|schemas/user.fbs': 'table User { id: int; name: string; }'},
        outputs: {
          'my_pkg|lib/schemas/user.g.dart':
              '// Generated FlatBuffer Dart code\nclass User {}',
        },
      );

      expect(call.executable, equals('flatc'));
      expect(call.args, contains('--dart'));
      expect(call.args, contains('--gen-mutable'));
      expect(
        await File(call.input).exists(),
        isFalse,
        reason: 'temp dir is cleaned up',
      );
    });

    test(
      'successful code generation for custom paths and nested subdirectories',
      () async {
        final builder = FlatcBuilder(
          inputDir: 'custom_fbs',
          outputDir: 'lib/models',
          runProcess: fakeFlatc(
            {'monster_generated.dart': 'class Monster {}'},
            expectStaged: ['custom_fbs/game/monster.fbs'],
          ),
        );

        await testBuilder(
          builder,
          {
            'my_pkg|custom_fbs/game/monster.fbs':
                'table Monster { hp: short; }',
          },
          outputs: {
            'my_pkg|lib/models/game/monster.g.dart': 'class Monster {}',
          },
        );
      },
    );

    test('stages transitive includes through the build step', () async {
      final builder = FlatcBuilder(
        runProcess: fakeFlatc(
          {'user_generated.dart': '// User'},
          primary: 'user.fbs',
          expectStaged: [
            'schemas/user.fbs',
            'schemas/common/types.fbs',
            'schemas/common/base.fbs',
          ],
        ),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs':
              'include "common/types.fbs"; table User {}',
          // Relative to the including file.
          'my_pkg|schemas/common/types.fbs': 'include "base.fbs"; table T {}',
          'my_pkg|schemas/common/base.fbs': 'table B {}',
        },
        outputs: {
          'my_pkg|lib/schemas/user.g.dart': '// User',
          'my_pkg|lib/schemas/common/types.g.dart': '',
          'my_pkg|lib/schemas/common/base.g.dart': '',
        },
      );
    });

    test('missing include logs a severe error', () async {
      final logs = <LogRecord>[];
      var called = false;
      final builder = FlatcBuilder(
        runProcess: (executable, args, {workingDirectory}) async {
          called = true;
          return ProcessResult(1234, 0, '', '');
        },
      );

      await testBuilder(
        builder,
        {'my_pkg|schemas/user.fbs': 'include "missing.fbs"; table User {}'},
        outputs: {},
        onLog: logs.add,
      );

      expect(called, isFalse);
      expect(
        _hasSevere(logs, 'Unable to resolve include "missing.fbs"'),
        isTrue,
      );
      expect(_hasSevere(logs, 'schemas/missing.fbs'), isTrue);
    });

    test('rewrites imports of included schemas in the same directory', () async {
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({
          'monster_my_game_generated.dart':
              "import 'package:flat_buffers/flat_buffers.dart' as fb;\n"
              "import './types_common_generated.dart' as common;\n"
              "import './weapon_generated.dart';\n",
        }, primary: 'monster.fbs'),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/monster.fbs':
              'include "types.fbs";\ninclude "weapon.fbs";\nnamespace MyGame;',
          'my_pkg|schemas/types.fbs': 'namespace Common; struct V { x: int; }',
          'my_pkg|schemas/weapon.fbs': 'table Weapon {}',
        },
        outputs: {
          'my_pkg|lib/schemas/types.g.dart': '',
          'my_pkg|lib/schemas/weapon.g.dart': '',
          'my_pkg|lib/schemas/monster.g.dart':
              "import 'package:flat_buffers/flat_buffers.dart' as fb;\n"
              "import 'types.g.dart' as common;\n"
              "import 'weapon.g.dart';\n",
        },
      );
    });

    test('rewrites imports across nested directories', () async {
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({
          'monster_game_generated.dart':
              "import './types_common_generated.dart' as common;\n",
        }, primary: 'monster.fbs'),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/game/monster.fbs':
              'include "common/types.fbs";\nnamespace Game;',
          // Resolved relative to input_dir.
          'my_pkg|schemas/common/types.fbs': 'namespace Common;',
        },
        outputs: {
          'my_pkg|lib/schemas/common/types.g.dart': '',
          'my_pkg|lib/schemas/game/monster.g.dart':
              "import '../common/types.g.dart' as common;\n",
        },
      );
    });

    test('longest include basename wins when mapping imports', () async {
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({
          'user_generated.dart':
              "import './types_extra_generated.dart' as extra;\n",
        }, primary: 'user.fbs'),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs':
              'include "types.fbs"; include "types_extra.fbs";',
          'my_pkg|schemas/types.fbs': 'namespace Extra;',
          'my_pkg|schemas/types_extra.fbs': '',
        },
        outputs: {
          'my_pkg|lib/schemas/types.g.dart': '',
          'my_pkg|lib/schemas/types_extra.g.dart': '',
          'my_pkg|lib/schemas/user.g.dart':
              "import 'types_extra.g.dart' as extra;\n",
        },
      );
    });

    test('include outside input_dir logs a severe error', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        runProcess: fakeFlatc(
          {'user_generated.dart': "import './shared_generated.dart';\n"},
          expectStaged: ['third_party/shared.fbs'],
        ),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs': 'include "third_party/shared.fbs";',
          'my_pkg|third_party/shared.fbs': 'table S {}',
        },
        outputs: {},
        onLog: logs.add,
      );

      expect(_hasSevere(logs, 'is outside input_dir'), isTrue);
    });

    test('includes sharing a basename log a severe error', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({
          'user_generated.dart': "import './types_generated.dart';\n",
        }, primary: 'user.fbs'),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs':
              'include "a/types.fbs"; include "b/types.fbs";',
          'my_pkg|schemas/a/types.fbs': '',
          'my_pkg|schemas/b/types.fbs': '',
        },
        outputs: {
          'my_pkg|lib/schemas/a/types.g.dart': '',
          'my_pkg|lib/schemas/b/types.g.dart': '',
        },
        onLog: logs.add,
      );

      expect(_hasSevere(logs, 'is ambiguous'), isTrue);
    });

    test('multiple namespaces in one schema log a severe error', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({
          'user_a_generated.dart': '// A',
          'user_b_generated.dart': '// B',
        }),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/user.fbs':
              'namespace A; table X {} namespace B; table Y {}',
        },
        outputs: {},
        onLog: logs.add,
      );

      expect(_hasSevere(logs, 'declares multiple namespaces'), isTrue);
      expect(
        _hasSevere(logs, 'user_a_generated.dart, user_b_generated.dart'),
        isTrue,
      );
    });

    test(
      'handles missing flatc executable (ProcessException) with severe log',
      () async {
        final logs = <LogRecord>[];
        final builder = FlatcBuilder(
          flatcPath: 'non_existent_flatc',
          runProcess: (executable, args, {workingDirectory}) async {
            throw ProcessException(executable, args, 'Executable not found', 2);
          },
        );

        await testBuilder(
          builder,
          {'my_pkg|schemas/user.fbs': 'table User {}'},
          outputs: {},
          onLog: logs.add,
        );

        expect(
          _hasSevere(logs, 'Failed to execute flatc at "non_existent_flatc"'),
          isTrue,
        );
      },
    );

    test('unexpected errors are logged with their stack trace', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        runProcess: (executable, args, {workingDirectory}) async {
          throw StateError('boom');
        },
      );

      await testBuilder(
        builder,
        {'my_pkg|schemas/user.fbs': 'table User {}'},
        outputs: {},
        onLog: logs.add,
      );

      // build_runner folds the error and stack trace into the message.
      final record = logs.firstWhere((l) => l.level >= Level.SEVERE);
      expect(record.message, contains('Unexpected error running flatc'));
      expect(record.message, contains('Bad state: boom'));
      expect(record.message, contains('FlatcBuilder.build'));
    });

    test(
      'handles non-zero exit code with severe log containing stderr/stdout',
      () async {
        final logs = <LogRecord>[];
        final builder = FlatcBuilder(
          runProcess: (executable, args, {workingDirectory}) async {
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
          {'my_pkg|schemas/invalid.fbs': 'table Invalid { u: UnknownType; }'},
          outputs: {},
          onLog: logs.add,
        );

        expect(
          logs.any(
            (l) =>
                l.level >= Level.SEVERE &&
                l.message.contains('flatc failed with exit code 1') &&
                l.message.contains('error: unknown type `UnknownType`'),
          ),
          isTrue,
        );
      },
    );

    test('handles zero exit code when no .dart files were created', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(runProcess: fakeFlatc({}));

      await testBuilder(
        builder,
        {'my_pkg|schemas/empty.fbs': '// empty schema'},
        outputs: {},
        onLog: logs.add,
      );

      expect(
        _hasSevere(
          logs,
          'flatc succeeded with exit code 0 but generated no .dart files',
        ),
        isTrue,
      );
      expect(_hasSevere(logs, 'declares no types and has no includes'), isTrue);
    });
  });

  group('Include-only schemas', () {
    test('generate a barrel exporting their direct includes', () async {
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({}, primary: 'main.fbs'),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/main.fbs': '''
include "pe/pe.fbs";
include "pe/pe_x32.fbs";
include "pe/pe_x64.fbs";
include "pe/pe.fbs";
''',
          'my_pkg|schemas/pe/pe.fbs': 'table Header {}',
          'my_pkg|schemas/pe/pe_x32.fbs': 'include "pe.fbs"; table X32 {}',
          'my_pkg|schemas/pe/pe_x64.fbs': 'include "pe.fbs"; table X64 {}',
        },
        outputs: {
          'my_pkg|lib/schemas/main.g.dart':
              '// Generated by flat_buffers_generator from schemas/main.fbs. '
              'Do not edit.\n'
              '\n'
              "export 'pe/pe.g.dart';\n"
              "export 'pe/pe_x32.g.dart';\n"
              "export 'pe/pe_x64.g.dart';\n",
          'my_pkg|lib/schemas/pe/pe.g.dart': '',
          'my_pkg|lib/schemas/pe/pe_x32.g.dart': '',
          'my_pkg|lib/schemas/pe/pe_x64.g.dart': '',
        },
      );
    });

    test('barrel paths are relative to the output directory', () async {
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({}, primary: 'all.fbs'),
      );

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/game/all.fbs': 'include "common/types.fbs";',
          'my_pkg|schemas/common/types.fbs': 'table T {}',
        },
        outputs: {
          'my_pkg|lib/schemas/game/all.g.dart': decodedMatches(
            contains("export '../common/types.g.dart';\n"),
          ),
          'my_pkg|lib/schemas/common/types.g.dart': '',
        },
      );
    });

    test('include outside input_dir logs a severe error', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(runProcess: fakeFlatc({}));

      await testBuilder(
        builder,
        {
          'my_pkg|schemas/main.fbs': 'include "third_party/shared.fbs";',
          'my_pkg|third_party/shared.fbs': 'table S {}',
        },
        outputs: {},
        onLog: logs.add,
      );

      expect(_hasSevere(logs, 'is outside input_dir'), isTrue);
    });
  });

  group('Build sources check', () {
    List<LogRecord> warnings(List<LogRecord> logs) => logs
        .where((l) => l.level == Level.WARNING)
        .where((l) => l.message.contains('additional_public_assets'))
        .toList();

    test('warns when schemas exist on disk but are not sources', () async {
      final logs = <LogRecord>[];
      final checked = <String>[];
      final builder = FlatcBuilder(
        hasSchemasOnDisk: (dir) {
          checked.add(dir);
          return true;
        },
      );

      await testBuilder(
        builder,
        {'my_pkg|lib/main.dart': 'void main() {}'},
        outputs: {},
        onLog: logs.add,
      );

      expect(checked, equals(['schemas']));
      expect(warnings(logs), hasLength(1));
      expect(warnings(logs).single.message, contains('- "schemas/**"'));
    });

    test('does not warn when there are no schemas on disk', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(hasSchemasOnDisk: (_) => false);

      await testBuilder(
        builder,
        {'my_pkg|lib/main.dart': 'void main() {}'},
        outputs: {},
        onLog: logs.add,
      );

      expect(warnings(logs), isEmpty);
    });

    test('does not warn when schemas are sources', () async {
      final logs = <LogRecord>[];
      final builder = FlatcBuilder(
        runProcess: fakeFlatc({'user_generated.dart': '// User'}),
        hasSchemasOnDisk: (_) => fail('disk should not be checked'),
      );

      await testBuilder(
        builder,
        {'my_pkg|schemas/user.fbs': 'table User {}'},
        outputs: {'my_pkg|lib/schemas/user.g.dart': '// User'},
        onLog: logs.add,
      );

      expect(warnings(logs), isEmpty);
    });
  });

  group('Real flatc binary compilation', () {
    test('compiles real schema file into Dart code', () async {
      await testBuilder(
        FlatcBuilder(),
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
          'my_pkg|lib/schemas/monster.g.dart': decodedMatches(
            contains('Monster'),
          ),
        },
      );
    });

    test('compiles schemas with includes across namespaces', () async {
      await testBuilder(
        FlatcBuilder(),
        {
          'my_pkg|schemas/common.fbs': '''
namespace Common;

struct Vec3 { x: float; y: float; z: float; }
''',
          'my_pkg|schemas/monster.fbs': '''
include "common.fbs";

namespace MyGame.Sample;

table Monster {
  pos: Common.Vec3;
  hp: short = 100;
}

root_type Monster;
''',
        },
        outputs: {
          'my_pkg|lib/schemas/common.g.dart': decodedMatches(
            contains('class Vec3'),
          ),
          'my_pkg|lib/schemas/monster.g.dart': decodedMatches(
            allOf(
              contains("import 'common.g.dart' as common;"),
              isNot(contains('_generated.dart')),
              contains('common.Vec3'),
            ),
          ),
        },
      );
    });

    test('include-only schema generates a barrel', () async {
      await testBuilder(
        FlatcBuilder(),
        {
          'my_pkg|schemas/main.fbs': '''
include "pe/pe.fbs";
include "pe/pe_x32.fbs";
include "pe/pe_x64.fbs";
''',
          'my_pkg|schemas/pe/pe.fbs': '''
namespace Pe;
table Header { magic: uint; }
''',
          'my_pkg|schemas/pe/pe_x32.fbs': '''
include "pe.fbs";
namespace Pe.X32;
table OptionalHeader32 { header: Pe.Header; image_base: uint; }
''',
          'my_pkg|schemas/pe/pe_x64.fbs': '''
include "pe.fbs";
namespace Pe.X64;
table OptionalHeader64 { header: Pe.Header; image_base: ulong; }
''',
        },
        outputs: {
          'my_pkg|lib/schemas/main.g.dart': decodedMatches(
            allOf(
              contains("export 'pe/pe.g.dart';"),
              contains("export 'pe/pe_x32.g.dart';"),
              contains("export 'pe/pe_x64.g.dart';"),
            ),
          ),
          'my_pkg|lib/schemas/pe/pe.g.dart': decodedMatches(
            contains('class Header'),
          ),
          'my_pkg|lib/schemas/pe/pe_x32.g.dart': decodedMatches(
            contains("import 'pe.g.dart' as pe;"),
          ),
          'my_pkg|lib/schemas/pe/pe_x64.g.dart': decodedMatches(
            contains("import 'pe.g.dart' as pe;"),
          ),
        },
      );
    });

    test('invalid schema logs flatc error', () async {
      final logs = <LogRecord>[];
      await testBuilder(
        FlatcBuilder(),
        {'my_pkg|schemas/bad.fbs': 'table Bad { u: UnknownType; }'},
        outputs: {},
        onLog: logs.add,
      );
      expect(_hasSevere(logs, 'flatc failed'), isTrue);
    });
  }, skip: _flatcAvailable() ? false : 'flatc is not installed');
}
