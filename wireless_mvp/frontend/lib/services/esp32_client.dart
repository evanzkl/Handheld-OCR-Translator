import 'package:http/http.dart' as http;

/// Raised when the ESP32 is unreachable or returns a non-2xx response.
class Esp32Exception implements Exception {
  Esp32Exception(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thin client for the Freenove ESP32-S3 CameraWebServer firmware
/// (see PlatformIO ESP32 project, src/app_httpd.cpp):
///   GET :81/stream               -> MJPEG live view (consumed directly by Flutter)
///   GET /upload_job?job_id=..&backend_url=.. -> ESP32 captures a JPEG and uploads
///                                                it directly to the FastAPI job.
class Esp32Client {
  Esp32Client({required String baseUrl}) : baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), '');

  /// e.g. http://192.168.1.60 (no trailing slash, no path).
  final String baseUrl;

  /// The MJPEG stream is served on the same host, port 81.
  String get streamUrl {
    final uri = Uri.parse(baseUrl);
    return uri.replace(port: 81, path: '/stream').toString();
  }

  Future<bool> pollButtonEvent() async {
    final response = await http.get(Uri.parse('$baseUrl/button_event'));
    if (response.statusCode != 200) {
      throw Esp32Exception('ESP32 button event failed (HTTP ${response.statusCode})');
    }
    return response.body.contains('"capture_requested":true');
  }

  /// Tells the ESP32 to capture a still image and upload it directly to the
  /// backend job. The ESP32 performs the upload itself; Flutter never sees the bytes.
  Future<void> triggerCapture({required String jobId, required String backendBaseUrl}) async {
    final uri = Uri.parse('$baseUrl/upload_job').replace(queryParameters: {
      'job_id': jobId,
      'backend_url': backendBaseUrl,
    });
    final http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 15));
    } catch (exc) {
      throw Esp32Exception('Could not reach ESP32 at $baseUrl: $exc');
    }
    if (response.statusCode != 200) {
      throw Esp32Exception('ESP32 capture failed (HTTP ${response.statusCode}): ${response.body}');
    }
  }
}
