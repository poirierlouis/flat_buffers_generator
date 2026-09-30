import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Real build_runner execution', () {
    late Directory tempPkg;

    setUp(() async {
      tempPkg = await Directory.systemTemp.createTemp('fbs_e2e_');
    });

    tearDown(() async {
      if (await tempPkg.exists()) {
        await tempPkg.delete(recursive: true).catchError((_) => tempPkg);
      }
    });

    test('default configuration runs build_runner and produces lib/schemas/monster.g.dart', () async {
      final pubspec = File(p.join(tempPkg.path, 'pubspec.yaml'));
      final projectRoot = Directory.current.path.replaceAll(r'\', '/');
      await pubspec.writeAsString('''
name: e2e_sample
environment:
  sdk: ^3.13.4

dependencies:
  flat_buffers: any

dev_dependencies:
  build_runner: ^2.4.0
  flat_buffers_generator:
    path: $projectRoot
''');

      final buildYaml = File(p.join(tempPkg.path, 'build.yaml'));
      await buildYaml.writeAsString('''
targets:
  \$default:
    sources:
      - "schemas/**"
      - "lib/**"
      - "\$package\$"
''');

      final schemasDir = Directory(p.join(tempPkg.path, 'schemas'));
      await schemasDir.create(recursive: true);
      final fbsFile = File(p.join(schemasDir.path, 'monster.fbs'));
      await fbsFile.writeAsString('''
namespace MyGame.Sample;

table Monster {
  hp: short = 100;
  mana: short = 150;
  name: string;
}

root_type Monster;
''');

      final pubGetResult = await Process.run(
        'dart',
        ['pub', 'get'],
        workingDirectory: tempPkg.path,
        runInShell: true,
      );
      expect(
        pubGetResult.exitCode,
        equals(0),
        reason: pubGetResult.stderr.toString(),
      );

      final buildResult = await Process.run(
        'dart',
        ['run', 'build_runner', 'build'],
        workingDirectory: tempPkg.path,
        runInShell: true,
      );
      print(
        'Build runner output (default): ${buildResult.stdout}\n${buildResult.stderr}',
      );
      expect(
        buildResult.exitCode,
        equals(0),
        reason: buildResult.stderr.toString(),
      );

      final generatedFile = File(
        p.join(tempPkg.path, 'lib', 'schemas', 'monster.g.dart'),
      );
      expect(await generatedFile.exists(), isTrue);
      final content = await generatedFile.readAsString();
      expect(content, contains('Monster'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('custom configuration runs build_runner with custom input_dir and output_dir', () async {
      final pubspec = File(p.join(tempPkg.path, 'pubspec.yaml'));
      final projectRoot = Directory.current.path.replaceAll(r'\', '/');
      await pubspec.writeAsString('''
name: e2e_custom_sample
environment:
  sdk: ^3.13.4

dependencies:
  flat_buffers: any

dev_dependencies:
  build_runner: ^2.4.0
  flat_buffers_generator:
    path: $projectRoot
''');

      final buildYaml = File(p.join(tempPkg.path, 'build.yaml'));
      await buildYaml.writeAsString('''
targets:
  \$default:
    sources:
      - "custom_fbs/**"
      - "lib/**"
      - "\$package\$"
    builders:
      flat_buffers_generator:flatc_builder:
        options:
          input_dir: 'custom_fbs'
          output_dir: 'lib/models'
''');

      final customDir = Directory(p.join(tempPkg.path, 'custom_fbs'));
      await customDir.create(recursive: true);
      final fbsFile = File(p.join(customDir.path, 'monster.fbs'));
      await fbsFile.writeAsString('''
namespace MyGame.Sample;

table Monster {
  hp: short = 100;
  mana: short = 150;
  name: string;
}

root_type Monster;
''');

      final pubGetResult = await Process.run(
        'dart',
        ['pub', 'get'],
        workingDirectory: tempPkg.path,
        runInShell: true,
      );
      expect(
        pubGetResult.exitCode,
        equals(0),
        reason: pubGetResult.stderr.toString(),
      );

      final buildResult = await Process.run(
        'dart',
        ['run', 'build_runner', 'build'],
        workingDirectory: tempPkg.path,
        runInShell: true,
      );
      print(
        'Build runner output (custom): ${buildResult.stdout}\n${buildResult.stderr}',
      );
      expect(
        buildResult.exitCode,
        equals(0),
        reason: buildResult.stderr.toString(),
      );

      final generatedFile = File(
        p.join(tempPkg.path, 'lib', 'models', 'monster.g.dart'),
      );
      expect(
        await generatedFile.exists(),
        isTrue,
        reason: 'Expected lib/models/monster.g.dart to exist',
      );
      final content = await generatedFile.readAsString();
      expect(content, contains('Monster'));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
