enum PenType { fountain, ball, brush, highlighter }

extension PenTypeLabel on PenType {
  double get minWidth => this == PenType.highlighter ? 6 : .1;
  double get maxWidth => this == PenType.highlighter ? 40 : 8;
  String get label => switch (this) {
    PenType.fountain => 'Fountain Pen',
    PenType.ball => 'Ball Pen',
    PenType.brush => 'Brush Pen',
    PenType.highlighter => 'Highlighter',
  };
}

/// Immutable settings are copied into strokes so editing a preset never changes ink.
class PenStyle {
  const PenStyle({
    this.type = PenType.fountain,
    this.pressureSensitivity = .5,
    this.tipSharpness = .5,
  });
  final PenType type;
  final double pressureSensitivity;
  final double tipSharpness;

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'pressureSensitivity': pressureSensitivity,
    'tipSharpness': tipSharpness,
  };

  factory PenStyle.fromJson(Map<String, dynamic> json) {
    final type = PenType.values
        .where((type) => type.name == json['type'])
        .firstOrNull;
    final pressure = (json['pressureSensitivity'] as num).toDouble();
    final sharpness = (json['tipSharpness'] as num).toDouble();
    if (type == null ||
        !pressure.isFinite ||
        pressure < 0 ||
        pressure > 1 ||
        !sharpness.isFinite ||
        sharpness < 0 ||
        sharpness > 1) {
      throw const FormatException('Invalid pen style');
    }
    return PenStyle(
      type: type,
      pressureSensitivity: pressure,
      tipSharpness: sharpness,
    );
  }
}

class PenPreset {
  const PenPreset({
    required this.id,
    required this.name,
    required this.width,
    this.color = 0xff2947c7,
    this.style = const PenStyle(),
  });
  final String id;
  final String name;
  final double width;
  final int color;
  final PenStyle style;

  PenPreset copyWith({
    String? name,
    double? width,
    int? color,
    PenStyle? style,
  }) => PenPreset(
    id: id,
    name: name ?? this.name,
    width: width ?? this.width,
    color: color ?? this.color,
    style: style ?? this.style,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'width': width,
    'color': color,
    'style': style.toJson(),
  };

  factory PenPreset.fromJson(Map<String, dynamic> json) {
    final width = (json['width'] as num).toDouble();
    final style = PenStyle.fromJson(json['style'] as Map<String, dynamic>);
    final id = json['id'] as String;
    final name = json['name'] as String;
    if (!width.isFinite ||
        width < style.type.minWidth ||
        width > style.type.maxWidth ||
        id.isEmpty ||
        name.trim().isEmpty) {
      throw const FormatException('Invalid pen preset');
    }
    return PenPreset(
      id: id,
      name: name,
      width: width,
      color: json['color'] as int,
      style: style,
    );
  }

  static const highlighter = PenPreset(
    id: 'highlighter',
    name: 'Highlight',
    width: 16,
    color: 0xffffd740,
    style: PenStyle(type: PenType.highlighter),
  );

  static const defaults = [
    PenPreset(id: 'fountain', name: 'Fountain', width: 2.2),
    highlighter,
    PenPreset(
      id: 'ball',
      name: 'Fine ball',
      width: .35,
      style: PenStyle(type: PenType.ball, pressureSensitivity: .2),
    ),
    PenPreset(
      id: 'brush',
      name: 'Brush',
      width: 4,
      style: PenStyle(type: PenType.brush, pressureSensitivity: .8),
    ),
  ];
}
