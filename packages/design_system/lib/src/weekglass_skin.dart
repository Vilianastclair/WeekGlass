/// Skin changes optical color, never calendar categories or event data.
enum WeekGlassSkin {
  moonstone('moonstone', '月光冰蓝', '清澈冰蓝，保留熟悉的月光'),
  amethyst('amethyst', '雾紫水晶', '浅紫折光，安静而通透'),
  roseQuartz('rose_quartz', '玫瑰石英', '柔粉透光，轻盈而温润'),
  champagne('champagne', '香槟琥珀', '暖金微光，如日光穿过玻璃'),
  glacier('glacier', '冰川青', '冷青水色，清冽而克制'),
  graphite('graphite', '曜石银', '银灰映光，纯粹而沉静');

  const WeekGlassSkin(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;

  static WeekGlassSkin fromId(String? id) =>
      values.firstWhere((skin) => skin.id == id, orElse: () => moonstone);
}
