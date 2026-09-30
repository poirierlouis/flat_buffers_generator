import 'package:build/build.dart';
import 'package:flat_buffers_generator/flat_buffers_generator.dart';

void main() {
  // Creating a FlatcBuilder with default options (schemas/ -> lib/schemas/)
  final defaultBuilder = flatcBuilder(BuilderOptions.empty);
  print('Default FlatcBuilder buildExtensions: ${defaultBuilder.buildExtensions}');

  // Creating a FlatcBuilder with custom options
  final customBuilder = flatcBuilder(
    const BuilderOptions({
      'input_dir': 'custom_schemas',
      'output_dir': 'lib/models',
      'flatc_path': 'flatc',
      'extra_args': ['--gen-mutable'],
    }),
  );
  print('Custom FlatcBuilder buildExtensions: ${customBuilder.buildExtensions}');

  print(
    '\nTo generate FlatBuffers Dart classes from schemas/*.fbs in your project:\n'
    '  dart run build_runner build\n',
  );
}
