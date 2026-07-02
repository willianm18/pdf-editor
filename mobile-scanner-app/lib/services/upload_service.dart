import 'dart:io';

import 'package:http/http.dart' as http;

/// Thrown when the upload could not be completed.
class UploadException implements Exception {
  const UploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Uploads scanned page images to the Stirling-PDF backend.
///
/// Matches the existing backend contract exactly:
///   POST {uploadUrl}
///   multipart/form-data with a repeated field named "files" (one per image),
/// which is what the web frontend sends via `formData.append("files", file)`.
class UploadService {
  const UploadService();

  /// POSTs every path in [imagePaths] as a `files` part to [uploadUrl].
  ///
  /// ML Kit returns image locations that may be `file://` URIs; both plain
  /// paths and `file://` URIs are accepted.
  Future<void> uploadImages({
    required String uploadUrl,
    required List<String> imagePaths,
  }) async {
    if (imagePaths.isEmpty) {
      throw const UploadException('No images to upload.');
    }

    final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));
    for (final path in imagePaths) {
      final file = File(_toFilePath(path));
      request.files.add(
        await http.MultipartFile.fromPath(
          'files',
          file.path,
          filename: file.uri.pathSegments.isNotEmpty
              ? file.uri.pathSegments.last
              : 'scan.jpg',
        ),
      );
    }

    final http.StreamedResponse response;
    try {
      response = await request.send();
    } on SocketException catch (e) {
      throw UploadException('Network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw UploadException('Network error: ${e.message}');
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw UploadException(
        'Upload failed (HTTP ${response.statusCode}). ${body.isEmpty ? '' : body}'
            .trim(),
      );
    }
    // Drain the stream so the connection can be released.
    await response.stream.drain<void>();
  }

  static String _toFilePath(String pathOrUri) {
    if (pathOrUri.startsWith('file://')) {
      return Uri.parse(pathOrUri).toFilePath();
    }
    return pathOrUri;
  }
}
