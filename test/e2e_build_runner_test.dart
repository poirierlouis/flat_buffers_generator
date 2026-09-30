/// End-to-end tests running a real `build_runner` in temporary packages.
///
/// Requires `flatc` on PATH and network access for `dart pub get`. Run with
/// `dart test -t e2e`, or exclude with `dart test -x e2e`.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _monsterSchema = '''
namespace MyGame.Sample;

table Monster {
  hp: short = 100;
  mana: short = 150;
  name: string;
}

root_type Monster;
''';

bool _flatcAvailable() {
  try {
    return Process.runSync('flatc', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  group(
    'Real build_runner execution',
    () {
      late Directory tempPkg;

      setUp(() async {
        tempPkg = await Directory.systemTemp.createTemp('fbs_e2e_');
      });

      tearDown(() async {
        if (await tempPkg.exists()) {
          await tempPkg.delete(recursive: true).catchError((_) => tempPkg);
        }
      });

      File file(String path) =>
          File(p.joinAll([tempPkg.path, ...p.posix.split(path)]));

      Future<void> writeFile(String path, String content) async {
        final f = file(path);
        await f.parent.create(recursive: true);
        await f.writeAsString(content);
      }

      /// Writes a package with [buildYaml] and [files] (relative path ->
      /// content) into [tempPkg], then runs `dart pub get`.
      Future<void> createPackage({
        required String buildYaml,
        required Map<String, String> files,
      }) async {
        final projectRoot = Directory.current.path.replaceAll(r'\', '/');
        await File(p.join(tempPkg.path, 'pubspec.yaml')).writeAsString('''
name: e2e_sample
environment:
  sdk: ^3.11.0

dependencies:
  flat_buffers: ^25.9.23

dev_dependencies:
  build_runner: ^2.4.0
  flat_buffers_generator:
    path: $projectRoot
''');
        await File(p.join(tempPkg.path, 'build.yaml')).writeAsString(buildYaml);
        for (final entry in files.entries) {
          await writeFile(entry.key, entry.value);
        }

        final pubGet = await Process.run(
          'dart',
          ['pub', 'get'],
          workingDirectory: tempPkg.path,
          runInShell: true,
        );
        expect(pubGet.exitCode, equals(0), reason: pubGet.stderr.toString());
      }

      Future<ProcessResult> run(List<String> args) async {
        final result = await Process.run(
          'dart',
          args,
          workingDirectory: tempPkg.path,
          runInShell: true,
        );
        printOnFailure(
          'dart ${args.join(' ')} (exit ${result.exitCode}):\n'
          '${result.stdout}\n${result.stderr}',
        );
        return result;
      }

      Future<void> buildSucceeds() async {
        final result = await run(['run', 'build_runner', 'build']);
        expect(result.exitCode, equals(0), reason: result.stdout.toString());
      }

      test(
        'default configuration produces lib/schemas/monster.g.dart',
        () async {
          await createPackage(
            buildYaml: 'additional_public_assets: ["schemas/**"]\n',
            files: {
              'schemas/monster.fbs': _monsterSchema,
              // Other default sources keep working alongside the builder.
              'test/sample_test.dart': 'void main() {}\n',
            },
          );

          await buildSucceeds();

          final generated = file('lib/schemas/monster.g.dart');
          expect(await generated.exists(), isTrue);
          expect(await generated.readAsString(), contains('Monster'));
        },
      );

      test('custom input_dir and output_dir', () async {
        await createPackage(
          buildYaml: r'''
additional_public_assets: ["custom_fbs/**"]
targets:
  $default:
    builders:
      flat_buffers_generator:flatc_builder:
        options:
          input_dir: 'custom_fbs'
          output_dir: 'lib/models'
''',
          files: {'custom_fbs/monster.fbs': _monsterSchema},
        );

        await buildSucceeds();

        final generated = file('lib/models/monster.g.dart');
        expect(await generated.exists(), isTrue);
        expect(await generated.readAsString(), contains('Monster'));
      });

      test('includes across nested directories compile', () async {
        await createPackage(
          buildYaml: 'additional_public_assets: ["schemas/**"]\n',
          files: {
            'schemas/common/types.fbs': '''
namespace Common;

enum Color:byte { Red = 0, Green, Blue = 2 }

struct Vec3 { x: float; y: float; z: float; }
''',
            'schemas/game/monster.fbs': '''
include "common/types.fbs";

namespace MyGame.Sample;

table Monster {
  pos: Common.Vec3;
  color: Common.Color = Blue;
  hp: short = 100;
}

root_type Monster;
''',
            'lib/main.dart': '''
import 'schemas/common/types.g.dart' as common;
import 'schemas/game/monster.g.dart';

double roundTrip() {
  final bytes = MonsterObjectBuilder(
    pos: common.Vec3ObjectBuilder(x: 1, y: 2, z: 3),
    hp: 42,
  ).toBytes();
  return Monster(bytes).pos!.x;
}
''',
          },
        );

        await buildSucceeds();

        final monster = await file(
          'lib/schemas/game/monster.g.dart',
        ).readAsString();
        expect(monster, contains("import '../common/types.g.dart' as common;"));
        expect(file('lib/schemas/common/types.g.dart').existsSync(), isTrue);

        final analyze = await run(['analyze', '--no-fatal-warnings', 'lib']);
        expect(analyze.exitCode, equals(0), reason: analyze.stdout.toString());
      });

      test('include-only schema generates a usable barrel', () async {
        await createPackage(
          buildYaml: 'additional_public_assets: ["schemas/**"]\n',
          files: {
            'schemas/main.fbs': '''
include "pe/pe.fbs";
include "pe/pe_x32.fbs";
include "pe/pe_x64.fbs";
''',
            'schemas/pe/pe.fbs': '''
namespace Pe;
table Header { magic: uint; }
''',
            'schemas/pe/pe_x32.fbs': '''
include "pe.fbs";
namespace Pe.X32;
table OptionalHeader32 { header: Pe.Header; image_base: uint; }
''',
            'schemas/pe/pe_x64.fbs': '''
include "pe.fbs";
namespace Pe.X64;
table OptionalHeader64 { header: Pe.Header; image_base: ulong; }
''',
            'lib/main.dart': '''
import 'schemas/main.g.dart';

int magic(List<int> bytes) => OptionalHeader64(bytes).header!.magic;

List<int> build() => OptionalHeader32ObjectBuilder(
  header: HeaderObjectBuilder(magic: 0x4550),
  imageBase: 0x400000,
).toBytes();
''',
          },
        );

        await buildSucceeds();

        expect(
          await file('lib/schemas/main.g.dart').readAsString(),
          contains("export 'pe/pe_x64.g.dart';"),
        );
        final analyze = await run(['analyze', '--no-fatal-warnings', 'lib']);
        expect(analyze.exitCode, equals(0), reason: analyze.stdout.toString());
      });

      test('warns when schemas are not build sources', () async {
        await createPackage(
          buildYaml: '# no additional_public_assets\n',
          files: {'schemas/monster.fbs': _monsterSchema},
        );

        final result = await run(['run', 'build_runner', 'build']);
        final output = '${result.stdout}${result.stderr}';
        expect(output, contains('none of them are build sources'));
        expect(output, contains('additional_public_assets'));
        expect(file('lib/schemas/monster.g.dart').existsSync(), isFalse);
      });

      test('invalid schema makes build_runner fail', () async {
        await createPackage(
          buildYaml: 'additional_public_assets: ["schemas/**"]\n',
          files: {'schemas/bad.fbs': 'table Bad { u: UnknownType; }\n'},
        );

        final result = await run(['run', 'build_runner', 'build']);
        expect(result.exitCode, isNot(equals(0)));
        expect(
          '${result.stdout}${result.stderr}',
          contains('flatc failed with exit code'),
        );
      });

      test('editing an included schema regenerates dependents', () async {
        await createPackage(
          buildYaml: 'additional_public_assets: ["schemas/**"]\n',
          files: {
            'schemas/enums.fbs': '''
namespace Common;
enum Color:byte { Red = 0, Green, Blue = 2 }
''',
            'schemas/monster.fbs': '''
include "enums.fbs";
namespace Game;
table Monster { color: Common.Color = Blue; }
''',
          },
        );

        await buildSucceeds();
        final monster = file('lib/schemas/monster.g.dart');
        // The default enum value is inlined into the dependent output.
        expect(await monster.readAsString(), contains('4, 2)'));

        await writeFile('schemas/enums.fbs', '''
namespace Common;
enum Color:byte { Red = 0, Green, Blue = 5 }
''');
        await buildSucceeds();

        final updated = await monster.readAsString();
        expect(updated, contains('4, 5)'));
        expect(updated, isNot(contains('4, 2)')));
      });
    },
    skip: _flatcAvailable() ? false : 'flatc is not installed',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
