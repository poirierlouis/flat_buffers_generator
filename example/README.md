# flat_buffers_generator example

A small package that generates Dart code from FlatBuffers schemas with
`flat_buffers_generator`.

## Structure

- `schemas/monster.fbs`: the `Monster` table. It includes `common/vec3.fbs`.
- `schemas/common/vec3.fbs`: a shared `Vec3` struct, in its own namespace.
- `build.yaml`: adds `schemas/**` to the build sources with
  `additional_public_assets`.
- `lib/schemas/`: generated code (committed so the example analyzes without a build).
- `flat_buffers_generator_example.dart`: builds a `Monster` buffer and reads it back.

## Running

Make sure `flatc` is installed, then:

```bash
dart pub get
dart run build_runner build   # or: dart run build_runner watch
dart run flat_buffers_generator_example.dart
```

With `watch` running, editing `schemas/common/vec3.fbs` also regenerates
`lib/schemas/monster.g.dart`, because it includes that file.
