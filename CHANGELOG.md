# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Schemas using `include` now generate compiling code: the `import`s written by flatc are rewritten to point to the
  `.g.dart` output of each included schema.
- Included schemas are read through `build_runner`, so editing an included file regenerates the schemas that
  include it (`watch` and incremental builds). Schemas are no longer read directly from disk.
- A schema declaring several namespaces is now reported as an error instead of silently dropping code.
- Unexpected errors while running flatc are logged with their stack trace.

### Changed

- `extra_args` conflicting with the builder (`-o`, `-I`, `--gen-all`, `--filename-suffix`, `--filename-ext`,
  non-Dart generators) and `input_dir == output_dir` are rejected with an `ArgumentError`.
- The SDK constraint is lowered to `^3.11.0`.
- The README recommends `additional_public_assets: ["schemas/**"]` instead of a partial `sources` list, which turned
  off other builders, and pins `flat_buffers` to the flatc major version (`^25.x`).

### Added

- A schema that only `include`s other schemas (and declares no types) generates a barrel `.g.dart` exporting the
  outputs of its direct includes, instead of failing with "generated no .dart files".
- A warning when `input_dir` holds `.fbs` files that aren't build sources (e.g. missing
  `additional_public_assets: ["schemas/**"]`), instead of silently generating nothing.
- Documented include resolution, the one-namespace-per-file rule and other limitations.
- A runnable `example/` package, using an include.
- `e2e` test tag (`dart test -x e2e` skips the tests that run a real `build_runner`).

## [1.0.0] - 2026-09-30

### Added

- Initial version.

<!-- Table of links -->
[unreleased]: https://github.com/poirierlouis/flat_buffers_generator/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/poirierlouis/flat_buffers_generator/releases/tag/v1.0.0