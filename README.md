# flat_buffers_generator

A Dart `build_runner` code generator that compiles FlatBuffers schema (`.fbs`) files into Dart code (`.g.dart`) using the official FlatBuffers compiler (`flatc`).

## Features

- **Automated Generation**: Generates Dart classes from `.fbs` schemas using standard Dart build tooling (`dart run build_runner build`).
- **Flexible File Placement**: Defaults to compiling files from `schemas/` into `lib/schemas/`, fully customizable via `build.yaml`.
- **Custom Compiler Flags**: Pass additional compiler arguments (e.g. `--gen-mutable`) directly to `flatc`.
- **Clear Error Reporting**: Descriptive error messages with compiler output when compilation fails or `flatc` is not installed.

## Prerequisites

The FlatBuffers compiler (`flatc`) must be installed on your machine and available in your `PATH` (or configured via `flatc_path` in `build.yaml`).

### Installing `flatc`

- **macOS** (Homebrew):
  ```bash
  brew install flatbuffers
  ```
- **Ubuntu / Debian**:
  ```bash
  sudo apt-get install flatbuffers-compiler
  ```
- **Windows** (Chocolatey / Scoop):
  ```bash
  choco install flatc
  # or
  scoop install flatbuffers
  ```
- **Manual**: Download precompiled binaries from the [FlatBuffers GitHub Releases](https://github.com/google/flatbuffers/releases).

## Getting Started

Add `flat_buffers_generator` and `build_runner` to your `pubspec.yaml`:

```yaml
dependencies:
  flat_buffers: ^25.9.23 # same major version as your flatc

dev_dependencies:
  build_runner: ^2.4.0
  flat_buffers_generator: ^1.0.0
```

The generated code targets the `flat_buffers` runtime of the same major version as the `flatc` that produced it
(check with `flatc --version`), so keep the two in sync.

Then tell `build_runner` to read your schemas. `schemas/` is not one of `build_runner`'s default source
directories, so without this the builder never runs. Add a `build.yaml` next to your `pubspec.yaml`:

```yaml
additional_public_assets:
  - "schemas/**"
```

`additional_public_assets` is added to the default sources, so other builders (`lib/`, `test/`, `bin/`, `web/`, …)
keep working. If `schemas/` holds `.fbs` files that aren't build sources, the build prints a warning pointing to
this setting instead of silently generating nothing.

> **Avoid a partial `sources` list.** `targets.$default.sources` *replaces* the default list. Something like
> `sources: ["schemas/**", "lib/**", "$package$"]` quietly drops `test/**`, `bin/**`, `web/**`, `pubspec.yaml`, …
> so builders such as `mockito` or `build_web_compilers` stop seeing their inputs. If you really need `sources`,
> list the defaults too:
>
> ```yaml
> targets:
>   $default:
>     sources:
>       - "schemas/**"
>       - "assets/**"
>       - "benchmark/**"
>       - "bin/**"
>       - "CHANGELOG*"
>       - "example/**"
>       - "lib/**"
>       - "test/**"
>       - "integration_test/**"
>       - "tool/**"
>       - "web/**"
>       - "node/**"
>       - "LICENSE*"
>       - "pubspec.yaml"
>       - "pubspec.lock"
>       - "README*"
>       - "$package$"
> ```

## Usage

### 1. Define your FlatBuffers schema

Create a `.fbs` schema file in the `schemas/` directory (e.g. `schemas/monster.fbs`):

```flatbuffers
include "common/vec3.fbs";

namespace MyGame.Sample;

enum Color:byte { Red = 0, Green, Blue = 2 }

table Monster {
  pos:MyGame.Common.Vec3;
  mana:short = 150;
  hp:short = 100;
  name:string;
  friendly:bool = false;
  inventory:[ubyte];
  color:Color = Blue;
}

root_type Monster;
```

with the shared struct in `schemas/common/vec3.fbs`:

```flatbuffers
namespace MyGame.Common;

struct Vec3 {
  x:float;
  y:float;
  z:float;
}
```

### 2. Run the builder

Run the build runner in your project:

```bash
dart run build_runner build
```

Each schema gets its own Dart file: `lib/schemas/monster.g.dart` and `lib/schemas/common/vec3.g.dart`. The
directory layout under `schemas/` is kept.

For active development, watch for file changes automatically:

```bash
dart run build_runner watch
```

Included schemas are tracked as dependencies, so editing `common/vec3.fbs` also regenerates `monster.g.dart`.

See [`example/`](example) for a complete package.

## Schema rules and limitations

- **Includes** are resolved the way `flatc` resolves them: relative to the including file, then relative to
  `input_dir`, then relative to the package root. Included files must be under `input_dir`: each one gets its own
  `.g.dart`, and the `import`s `flatc` writes are rewritten to point to it.
- **One namespace per file.** `flatc` writes one Dart file per namespace, which doesn't fit the one-schema →
  one-`.g.dart` model, so a schema declaring several namespaces is reported as an error. Move each namespace into
  its own file and use `include`.
- **Include-only schemas become barrels.** A schema that declares no types and only `include`s others (e.g. a
  `main.fbs` listing all your schemas) generates a `.g.dart` that `export`s the outputs of its direct includes:

  ```dart
  // lib/schemas/main.g.dart
  export 'pe/pe.g.dart';
  export 'pe/pe_x32.g.dart';
  export 'pe/pe_x64.g.dart';
  ```

  Dart puts every exported name in one namespace, so if two exported schemas declare the same type name (even in
  different FlatBuffers namespaces), the barrel fails to compile with `ambiguous_export`. Rename one of the types, or
  import the individual `.g.dart` files instead of the barrel.
- **Included schemas need distinct file names** (e.g. not both `a/types.fbs` and `b/types.fbs` in the same
  schema), because `flatc` imports them by file name only.
- **Output names:** outputs use the `.g.dart` extension, like `source_gen` builders. Don't keep a hand-written
  `lib/schemas/x.dart` that also uses a `source_gen` builder (`part 'x.g.dart';`), since both builders would claim
  `lib/schemas/x.g.dart`.
- **Unsupported `extra_args`:** `-o`, `-I`, `--gen-all`, `--filename-suffix`, `--filename-ext` and non-Dart
  generators (`--cpp`, `--java`, `--ts`, `-b`, …) conflict with how the builder runs `flatc` and are rejected when
  the build starts.

## Configuration

You can customize the input directory, output directory, compiler path, and extra arguments in your project's
`build.yaml`:

```yaml
additional_public_assets:
  - "schemas/**"

targets:
  $default:
    builders:
      flat_buffers_generator:flatc_builder:
        options:
          input_dir: 'schemas'
          output_dir: 'lib/schemas'
          flatc_path: 'flatc'
          extra_args:
            - '--gen-mutable'
```

### Custom Directory Example

To use a custom directory such as `custom_schemas/` and output to `lib/models/`:

```yaml
additional_public_assets:
  - "custom_schemas/**"

targets:
  $default:
    builders:
      flat_buffers_generator:flatc_builder:
        options:
          input_dir: 'custom_schemas'
          output_dir: 'lib/models'
```

A directory already in the default sources (e.g. `lib/fbs/`) doesn't need `additional_public_assets`.

### Configuration Options

| Option       | Type           | Default         | Description                                                                                  |
|--------------|----------------|-----------------|----------------------------------------------------------------------------------------------|
| `input_dir`  | `String`       | `'schemas'`     | Directory containing input `.fbs` schema files.                                              |
| `output_dir` | `String`       | `'lib/schemas'` | Directory where generated `.g.dart` files will be written. Must differ from `input_dir`.     |
| `flatc_path` | `String`       | `'flatc'`       | Path or command name for the `flatc` binary.                                                 |
| `extra_args` | `List<String>` | `[]`            | Additional command-line flags to pass to `flatc` (see [limitations](#schema-rules-and-limitations)). |
