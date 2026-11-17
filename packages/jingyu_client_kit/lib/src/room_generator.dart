/// 内置房间生成器：把用户的房间 brief 映射为**纯布局数据**。
///
/// 复用 feiyu-room-template 的"按提示词生成房间"方向
/// （见 docs/plugins/02-assets.md §2）：五个风格预设、brief 字段与
/// [RoomLayout] 布局数据结构。**不复制模板素材**，也不生成、不下载任何
/// 可执行代码；全程是确定性的纯函数映射，无网络、无 IO。
///
/// 能力对应 `roomScene` + `modelInvoke`，id 为 `jingyu.room.generator`。
library;

import 'plugin.dart';

/// feiyu-room-template 的五个房间方向（顺序即界面展示顺序）。
const List<String> _presetStyles = <String>[
  '海边小屋',
  '森林木屋',
  '现代公寓',
  '赛博小屋',
  '中式小院',
];

/// 每个风格的默认户型：当 `brief.rooms` 为空时使用。
const Map<String, List<String>> _defaultRooms = <String, List<String>>{
  '海边小屋': <String>['客厅', '卧室', '厨房', '浴室'],
  '森林木屋': <String>['客厅', '卧室', '阁楼', '门廊'],
  '现代公寓': <String>['客厅', '卧室', '厨房', '书房'],
  '赛博小屋': <String>['休息舱', '工作间', '主机房', '控制室'],
  '中式小院': <String>['正房', '厢房', '庭院', '厨房'],
};

/// 每个风格的小型家具清单（每项的 `kind`）。
///
/// 家具位置在生成时按固定规则计算，因此同一 brief 永远得到同一布局。
const Map<String, List<String>> _furniturePalette = <String, List<String>>{
  '海边小屋': <String>['木床', '衣柜', '布艺沙发', '茶几', '落地窗'],
  '森林木屋': <String>['木床', '壁炉', '摇椅', '书架', '圆木餐桌'],
  '现代公寓': <String>['双人床', '衣柜', '布艺沙发', '电视柜', '书桌'],
  '赛博小屋': <String>['悬浮床', '控制台', '数据架', '全息屏', '充电舱'],
  '中式小院': <String>['罗汉床', '太师椅', '条案', '屏风', '花架'],
};

/// 家具摆放的确定性步长（单位：米）。
const double _roomWidth = 4.0;
const double _itemSpacing = 1.5;
const double _rowSpacing = 2.0;

/// 内置房间生成器：实现 [RoomGenerator]，确定性地产出 [RoomLayout]。
class FeiyuRoomGenerator implements RoomGenerator {
  const FeiyuRoomGenerator();

  @override
  String get id => 'jingyu.room.generator';

  @override
  List<String> get presets => _presetStyles;

  @override
  Future<RoomLayout> generate(RoomBrief brief, PluginContext context) async {
    final style = brief.style.trim();
    if (style.isEmpty) {
      throw ArgumentError.value(brief.style, 'brief.style', '风格不能为空');
    }
    if (brief.palette.trim().isEmpty) {
      throw ArgumentError.value(brief.palette, 'brief.palette', '主色不能为空');
    }
    if (brief.mood.trim().isEmpty) {
      throw ArgumentError.value(brief.mood, 'brief.mood', '氛围不能为空');
    }
    if (!_presetStyles.contains(style)) {
      throw ArgumentError.value(brief.style, 'brief.style', '未知风格');
    }

    final requested = <String>[
      for (final room in brief.rooms)
        if (room.trim().isNotEmpty) room.trim(),
    ];
    final rooms = requested.isEmpty
        ? List<String>.from(_defaultRooms[style]!)
        : requested;

    return RoomLayout(
      style: style,
      rooms: rooms,
      furniture: _generateFurniture(style, rooms),
    );
  }

  /// 从「对话文本」抽取房间 brief；无法识别时回退到现代公寓 + 中性配色。
  ///
  /// 纯关键字检测，对任意文本都安全（不抛异常）；`notes` 会去空白并截断到 500 字符。
  RoomBrief briefFromConversation(String prompt) {
    final text = prompt.trim();
    return RoomBrief(
      style: _detectStyle(text),
      palette: _detectPalette(text),
      mood: _detectMood(text),
      rooms: _detectRooms(text),
      notes: _truncate(text, 500),
    );
  }

  List<Map<String, Object?>> _generateFurniture(
    String style,
    List<String> rooms,
  ) {
    final palette = _furniturePalette[style]!;
    final furniture = <Map<String, Object?>>[];
    for (var i = 0; i < palette.length; i++) {
      final roomIndex = i % rooms.length;
      final column = i % 2;
      final row = i ~/ 2;
      // 只写入 {kind, room, x, y, rotation}：纯数据，不含下载/代码字段。
      furniture.add(<String, Object?>{
        'kind': palette[i],
        'room': rooms[roomIndex],
        'x': roomIndex * _roomWidth + column * _itemSpacing,
        'y': row * _rowSpacing,
        'rotation': (i % 4) * 90.0,
      });
    }
    return List<Map<String, Object?>>.unmodifiable(furniture);
  }

  String _detectStyle(String text) {
    const keywords = <String, List<String>>{
      '海边小屋': <String>['海边', '大海', '沙滩', '海景', '海岸'],
      '森林木屋': <String>['森林', '木屋', '树林', '原木', '林间'],
      '现代公寓': <String>['现代', '公寓', '都市', '简约', 'loft'],
      '赛博小屋': <String>['赛博', '朋克', '科技', '霓虹', '未来', 'cyber'],
      '中式小院': <String>['中式', '小院', '庭院', '四合院', '古风', '院子'],
    };
    for (final entry in keywords.entries) {
      if (entry.value.any(text.contains)) return entry.key;
    }
    return '现代公寓';
  }

  String _detectPalette(String text) {
    if (text.contains('霓虹') || text.contains('紫')) return '霓虹紫';
    if (text.contains('蓝') || text.contains('海')) return '蓝色';
    if (text.contains('绿') || text.contains('森林')) return '绿色';
    if (text.contains('暖') || text.contains('橙') || text.contains('黄')) {
      return '暖橙';
    }
    if (text.contains('木') || text.contains('棕')) return '木色';
    return '中性灰白';
  }

  String _detectMood(String text) {
    if (text.contains('安静') || text.contains('宁静') || text.contains('清静')) {
      return '宁静';
    }
    if (text.contains('温馨') || text.contains('温暖') || text.contains('暖')) {
      return '温馨';
    }
    if (text.contains('活泼') || text.contains('热闹') || text.contains('欢快')) {
      return '活泼';
    }
    if (text.contains('神秘')) return '神秘';
    if (text.contains('清爽') || text.contains('清新')) return '清爽';
    return '舒适';
  }

  List<String> _detectRooms(String text) {
    const known = <String>[
      '客厅', '卧室', '厨房', '书房', '浴室', '卫生间', '餐厅', '阳台', //
      '庭院', '阁楼', '门廊', '衣帽间', '儿童房', '工作间', '休息舱', //
      '控制室', '主机房', '正房', '厢房', '玄关',
    ];
    final rooms = <String>[];
    for (final room in known) {
      if (text.contains(room) && !rooms.contains(room)) rooms.add(room);
    }
    return rooms;
  }

  String _truncate(String text, int maxCodePoints) {
    final runes = text.runes;
    if (runes.length <= maxCodePoints) return text;
    return String.fromCharCodes(runes.take(maxCodePoints));
  }
}
