import 'dart:convert';
import 'dart:typed_data';

/// Fixed first-phase persona-card format. It carries exactly the writable
/// P0/P1/P2 layers; no memory, voice, avatar or version fields exist here.
const personaCardFormat = 'PRIVATE_AI_PERSONA_1';

/// Hard byte bound for the encoded card, checked before JSON decoding.
const personaCardMaxBytes = 64 * 1024;
const personaCardMaxEntries = 32;
const personaCardMaxKeyChars = 64;
const personaCardMaxValueChars = 2000;

/// One imported persona card. Immutable, ordered maps only.
///
/// Parsing is deliberately stricter than `jsonDecode`: duplicate keys, extra
/// fields, non-string values, control characters and length overflow are all
/// rejected. A failure message never includes card content.
class PersonaCard {
  PersonaCard._(this.p0, this.p1, this.p2);

  final Map<String, String> p0;
  final Map<String, String> p1;
  final Map<String, String> p2;

  int get entries => p0.length + p1.length + p2.length;

  String get summary =>
      'P0 ${p0.length} 项 · P1 ${p1.length} 项 · P2 ${p2.length} 项';

  String get formP0 => _formText('P0', p0);
  String get formP1 => _formText('P1', p1);
  String get formP2 => _formText('P2', p2);

  /// Parses raw card bytes. The size bound is applied before UTF-8/JSON.
  factory PersonaCard.parseBytes(List<int> bytes) {
    if (bytes.isEmpty) throw const FormatException('人格卡为空');
    if (bytes.length > personaCardMaxBytes) {
      throw const FormatException('人格卡超过 64 KiB');
    }
    // dart:utf8 strips a leading BOM; this format requires exact UTF-8 JSON.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      throw const FormatException('人格卡不允许 BOM');
    }
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const FormatException('人格卡不是有效 UTF-8');
    }
    return PersonaCard.parseText(text);
  }

  factory PersonaCard.parseText(String text) {
    // Pasted JSON does not pass through parseBytes; enforce the same wire bound
    // before the custom parser allocates/traverses the document.
    if (utf8.encode(text).length > personaCardMaxBytes) {
      throw const FormatException('人格卡超过 64 KiB');
    }
    final raw = _StrictJsonParser(text).parseDocument();
    if (raw is! Map<String, Object?>) {
      throw const FormatException('人格卡顶层必须是 JSON 对象');
    }
    const required = {'format', 'p0', 'p1', 'p2'};
    if (raw.length != required.length ||
        !required.every(raw.containsKey) ||
        raw['format'] != personaCardFormat) {
      throw const FormatException('人格卡必须恰好包含 format/p0/p1/p2，且格式固定');
    }
    return PersonaCard._(
      _layer('P0', raw['p0']),
      _layer('P1', raw['p1']),
      _layer('P2', raw['p2']),
    );
  }

  static Map<String, String> _layer(String label, Object? value) {
    if (value is! Map<String, Object?>) {
      throw FormatException('$label 必须是 JSON 对象');
    }
    if (value.isEmpty) throw FormatException('$label 不能为空');
    if (value.length > personaCardMaxEntries) {
      throw FormatException('$label 最多 32 项');
    }
    final result = <String, String>{};
    for (final entry in value.entries) {
      _checkText(label, '键', entry.key, personaCardMaxKeyChars);
      final rawValue = entry.value;
      if (rawValue is! String) throw FormatException('$label 的值必须是字符串');
      _checkText(label, '值', rawValue, personaCardMaxValueChars);
      result[entry.key] = rawValue;
    }
    return Map<String, String>.unmodifiable(result);
  }

  static void _checkText(
    String label,
    String field,
    String text,
    int maxChars,
  ) {
    if (text.isEmpty) throw FormatException('$label 的$field不能为空');
    if (text.runes.length > maxChars) {
      throw FormatException('$label 的$field超过 $maxChars 字符');
    }
    for (final unit in text.codeUnits) {
      if (unit <= 0x1f || (unit >= 0x7f && unit <= 0x9f)) {
        throw FormatException('$label 的$field不允许控制字符');
      }
    }
  }

  /// Existing editor form lines are trimmed `key=value` pairs. A card that
  /// cannot be represented there is refused rather than silently altered.
  static String _formText(String label, Map<String, String> fields) {
    final lines = StringBuffer();
    for (final entry in fields.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key.contains('=') || key != key.trim() || value != value.trim()) {
        throw FormatException('$label 的字段无法填入现有表单（键含等号或首尾空白）');
      }
      if (lines.isNotEmpty) lines.write('\n');
      lines.write('$key=$value');
    }
    return lines.toString();
  }
}

/// Minimal strict JSON parser with duplicate-key detection.
///
/// The production card is two object levels deep, so a small depth limit keeps
/// hostile nesting bounded. Values are returned as plain Dart maps/lists.
class _StrictJsonParser {
  _StrictJsonParser(this.source);

  final String source;
  int index = 0;
  int depth = 0;

  static const _maxDepth = 4;

  Object? parseDocument() {
    final value = _value();
    _whitespace();
    if (index != source.length) _fail('人格卡包含多余内容');
    return value;
  }

  Object? _value() {
    _whitespace();
    if (index >= source.length) _fail('人格卡不是完整 JSON');
    final char = source.codeUnitAt(index);
    if (char == 0x7b) return _object();
    if (char == 0x5b) return _array();
    if (char == 0x22) return _string();
    if (char == 0x74) return _literal('true', true);
    if (char == 0x66) return _literal('false', false);
    if (char == 0x6e) return _literal('null', null);
    if (char == 0x2d || (char >= 0x30 && char <= 0x39)) return _number();
    _fail('人格卡包含无效 JSON 值');
  }

  Map<String, Object?> _object() {
    _enter();
    index++;
    final result = <String, Object?>{};
    _whitespace();
    if (index < source.length && source.codeUnitAt(index) == 0x7d) {
      index++;
      _leave();
      return result;
    }
    while (true) {
      _whitespace();
      final key = _string();
      if (result.containsKey(key)) _fail('人格卡包含重复键');
      _whitespace();
      _expect(0x3a, '缺少冒号');
      result[key] = _value();
      _whitespace();
      if (index >= source.length) _fail('人格卡不是完整 JSON');
      final char = source.codeUnitAt(index);
      if (char == 0x2c) {
        index++;
        continue;
      }
      if (char == 0x7d) {
        index++;
        _leave();
        return result;
      }
      _fail('人格卡对象缺少逗号或结束符');
    }
  }

  List<Object?> _array() {
    _enter();
    index++;
    final result = <Object?>[];
    _whitespace();
    if (index < source.length && source.codeUnitAt(index) == 0x5d) {
      index++;
      _leave();
      return result;
    }
    while (true) {
      result.add(_value());
      _whitespace();
      if (index >= source.length) _fail('人格卡不是完整 JSON');
      final char = source.codeUnitAt(index);
      if (char == 0x2c) {
        index++;
        continue;
      }
      if (char == 0x5d) {
        index++;
        _leave();
        return result;
      }
      _fail('人格卡数组缺少逗号或结束符');
    }
  }

  String _string() {
    _expect(0x22, '缺少字符串');
    final buffer = StringBuffer();
    while (index < source.length) {
      final char = source.codeUnitAt(index++);
      if (char == 0x22) return buffer.toString();
      if (char <= 0x1f) _fail('字符串包含未转义控制字符');
      if (char != 0x5c) {
        buffer.writeCharCode(char);
        continue;
      }
      if (index >= source.length) _fail('字符串转义不完整');
      final escape = source.codeUnitAt(index++);
      switch (escape) {
        case 0x22:
        case 0x5c:
        case 0x2f:
          buffer.writeCharCode(escape);
        case 0x62:
          buffer.writeCharCode(0x08);
        case 0x66:
          buffer.writeCharCode(0x0c);
        case 0x6e:
          buffer.writeCharCode(0x0a);
        case 0x72:
          buffer.writeCharCode(0x0d);
        case 0x74:
          buffer.writeCharCode(0x09);
        case 0x75:
          if (index + 4 > source.length) _fail('字符串转义不完整');
          final hex = source.substring(index, index + 4);
          final code = int.tryParse(hex, radix: 16);
          if (code == null) _fail('字符串转义无效');
          buffer.writeCharCode(code);
          index += 4;
        default:
          _fail('字符串转义无效');
      }
    }
    _fail('字符串未结束');
  }

  Object? _literal(String word, Object? value) {
    if (!source.startsWith(word, index)) _fail('人格卡包含无效 JSON 值');
    index += word.length;
    return value;
  }

  num _number() {
    final start = index;
    while (index < source.length) {
      final char = source.codeUnitAt(index);
      if ((char >= 0x30 && char <= 0x39) ||
          char == 0x2d ||
          char == 0x2b ||
          char == 0x2e ||
          char == 0x45 ||
          char == 0x65) {
        index++;
      } else {
        break;
      }
    }
    final number = num.tryParse(source.substring(start, index));
    if (number == null) _fail('人格卡包含无效数字');
    return number;
  }

  void _whitespace() {
    while (index < source.length) {
      final char = source.codeUnitAt(index);
      if (char == 0x20 || char == 0x09 || char == 0x0a || char == 0x0d) {
        index++;
      } else {
        return;
      }
    }
  }

  void _enter() {
    if (++depth > _maxDepth) _fail('人格卡嵌套过深');
  }

  void _leave() => depth--;

  void _expect(int char, String message) {
    if (index >= source.length || source.codeUnitAt(index) != char) {
      _fail(message);
    }
    index++;
  }

  Never _fail(String message) => throw FormatException(message);
}

/// Convenience for tests and callers that already hold UTF-8 bytes.
PersonaCard personaCardFromUtf8(Uint8List bytes) =>
    PersonaCard.parseBytes(bytes);
