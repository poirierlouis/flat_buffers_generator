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
  flat_buffers: ^23.5.26 # or latest compatible FlatBuffers runtime

dev_dependencies:
  build_runner: ^2.4.0
  flat_buffers_generator: ^1.0.0
```

## Usage

### 1. Define your FlatBuffers schema

Create a `.fbs` schema file in the `schemas/` directory (e.g. `schemas/monster.fbs`):

```flatbuffers
namespace MyGame.Sample;

enum Color:byte { Red = 0, Green, Blue = 2 }

struct Vec3 {
  x:float;
  y:float;
  z:float;
}

table Monster {
  pos:Vec3;
  mana:short = 150;
  hp:short = 100;
  name:string;
  friendly:bool = false;
  inventory:[ubyte];
  color:Color = Blue;
}

root_type Monster;
```

### 2. Run the builder

Run the build runner in your project:

```bash
dart run build_runner build
```

The generated Dart code will be written to `lib/schemas/monster.g.dart`.

For active development, watch for file changes automatically:

```bash
dart run build_runner watch
```

## Configuration

You can customize the input directory, output directory, compiler path, and extra arguments by adding a `build.yaml` file to your project root.

> **Note on Root-Level Directories:** Because `build_runner` scans standard folders (`lib/**`, `bin/**`, etc.) by default, any root-level schema folder (such as `schemas/**` or a custom directory) should be included in the target's `sources`:

```yaml
targets:
  $default:
    sources:
      - "schemas/**"
      - "lib/**"
      - "$package$"
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
targets:
  $default:
    sources:
      - "custom_schemas/**"
      - "lib/**"
      - "$package$"
    builders:
      flat_buffers_generator:flatc_builder:
        options:
          input_dir: 'custom_schemas'
          output_dir: 'lib/models'
```

### Configuration Options

| Option       | Type           | Default         | Description                                                |
|--------------|----------------|-----------------|------------------------------------------------------------|
| `input_dir`  | `String`       | `'schemas'`     | Directory containing input `.fbs` schema files.            |
| `output_dir` | `String`       | `'lib/schemas'` | Directory where generated `.g.dart` files will be written. |
| `flatc_path` | `String`       | `'flatc'`       | Path or command name for the `flatc` binary.               |
| `extra_args` | `List<String>` | `[]`            | Additional command-line flags to pass to `flatc`.          |
