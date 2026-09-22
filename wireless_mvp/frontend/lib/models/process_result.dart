/// Result of `POST /api/process`: a base64-encoded translated/blurred image
/// plus the OCR confidence and processing time reported by the backend.
class ProcessResult {
  const ProcessResult({
    required this.imageBase64,
    required this.imageFormat,
    required this.accuracy,
    required this.processingTimeSeconds,
  });

  final String imageBase64;
  final String imageFormat;
  final double accuracy;
  final double processingTimeSeconds;

  factory ProcessResult.fromJson(Map<String, dynamic> json) {
    return ProcessResult(
      imageBase64: json['image_base64'] as String,
      imageFormat: json['image_format'] as String,
      accuracy: (json['accuracy'] as num).toDouble(),
      processingTimeSeconds: (json['processing_time_seconds'] as num).toDouble(),
    );
  }
}
