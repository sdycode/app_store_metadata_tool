class AscResource {
  final String id;
  final String type;
  final Map<String, dynamic> attributes;
  final Map<String, dynamic> relationships;

  AscResource({
    required this.id,
    required this.type,
    required this.attributes,
    required this.relationships,
  });

  factory AscResource.fromJson(Map<String, dynamic> j) => AscResource(
        id: j['id'] as String,
        type: j['type'] as String,
        attributes: (j['attributes'] as Map<String, dynamic>?) ?? const {},
        relationships:
            (j['relationships'] as Map<String, dynamic>?) ?? const {},
      );
}

class AscUploadOperation {
  final String method;
  final String url;
  final int length;
  final int offset;
  final List<AscUploadHeader> requestHeaders;

  AscUploadOperation({
    required this.method,
    required this.url,
    required this.length,
    required this.offset,
    required this.requestHeaders,
  });

  factory AscUploadOperation.fromJson(Map<String, dynamic> j) =>
      AscUploadOperation(
        method: (j['method'] ?? 'PUT') as String,
        url: j['url'] as String,
        length: (j['length'] as num).toInt(),
        offset: (j['offset'] as num).toInt(),
        requestHeaders: ((j['requestHeaders'] as List?) ?? const [])
            .map((e) => AscUploadHeader.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class AscUploadHeader {
  final String name;
  final String value;

  AscUploadHeader({required this.name, required this.value});

  factory AscUploadHeader.fromJson(Map<String, dynamic> j) => AscUploadHeader(
        name: j['name'] as String,
        value: j['value'] as String,
      );
}
