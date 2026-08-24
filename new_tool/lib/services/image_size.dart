import 'dart:typed_data';

/// Header-only image dimension readers.
///
/// Both the uploader and the pre-flight validator need to know a file's
/// pixel size without pulling in an image-decoding package, so the PNG /
/// JPEG header parsing lives here and is shared by both.
///
/// Returns `{'width': w, 'height': h}` or null when the bytes are neither
/// a PNG nor a JPEG we can read.
Map<String, int>? readImageSize(Uint8List bytes) {
  final png = readPngSize(bytes);
  if (png != null) return png;
  final jpg = readJpegSize(bytes);
  if (jpg != null) return jpg;
  return null;
}

Map<String, int>? readPngSize(Uint8List bytes) {
  if (bytes.length < 24) return null;
  const pngSig = [137, 80, 78, 71, 13, 10, 26, 10];
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != pngSig[i]) return null;
  }
  final w =
      (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
  final h =
      (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
  return {'width': w, 'height': h};
}

Map<String, int>? readJpegSize(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 3 < b.length) {
    if (b[i] != 0xFF) return null;
    while (i < b.length && b[i] == 0xFF) {
      i++;
    }
    if (i >= b.length) return null;
    final marker = b[i];
    i++;
    if (marker == 0xD8 ||
        marker == 0xD9 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }
    if (i + 1 >= b.length) return null;
    final segLen = (b[i] << 8) | b[i + 1];
    final isSof = (marker >= 0xC0 && marker <= 0xCF) &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (i + 7 >= b.length) return null;
      final h = (b[i + 3] << 8) | b[i + 4];
      final w = (b[i + 5] << 8) | b[i + 6];
      return {'width': w, 'height': h};
    }
    i += segLen;
  }
  return null;
}
