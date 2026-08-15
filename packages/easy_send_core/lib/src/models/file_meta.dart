/// 전송할 파일 1개의 메타데이터 — prepare-upload의 files 항목 (PRD 4.3).
class FileMeta {
  const FileMeta({required this.name, required this.size, required this.mime});

  final String name;
  final int size;
  final String mime;

  Map<String, dynamic> toJson() => {'name': name, 'size': size, 'mime': mime};

  static FileMeta? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    final size = json['size'];
    final mime = json['mime'];
    if (name is! String || size is! int || mime is! String) return null;
    return FileMeta(name: name, size: size, mime: mime);
  }
}
