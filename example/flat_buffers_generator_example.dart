// Run `dart run build_runner build` in this directory to (re)generate
// `lib/schemas/**.g.dart` from `schemas/**.fbs`.
import 'package:flat_buffers_generator_example/schemas/common/vec3.g.dart'
    as common;
import 'package:flat_buffers_generator_example/schemas/monster.g.dart';

void main() {
  final bytes = MonsterObjectBuilder(
    pos: common.Vec3ObjectBuilder(x: 1, y: 2, z: 3),
    name: 'Orc',
    hp: 300,
    inventory: [0, 1, 2, 3],
    color: Color.Red,
  ).toBytes();

  final monster = Monster(bytes);
  print(
    '${monster.name}: hp=${monster.hp}, mana=${monster.mana}, '
    'pos=(${monster.pos!.x}, ${monster.pos!.y}, ${monster.pos!.z}), '
    'color=${monster.color}, inventory=${monster.inventory}',
  );
}
