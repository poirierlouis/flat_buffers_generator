# flat_buffers_generator Example

This directory contains a sample FlatBuffers schema and shows how to use `flat_buffers_generator`.

## Structure

- `schemas/monster.fbs`: A sample FlatBuffers schema definition.
- `flat_buffers_generator_example.dart`: Example code demonstrating builder initialization and configuration.

## Running the Builder

Ensure `flatc` is installed, then run `build_runner`:

```bash
dart run build_runner build
```

The generated code will be placed into `lib/schemas/monster.g.dart`.
