class LanguageInfo {
  LanguageInfo({
    required this.displayName,
    required this.ocrCode,
    required this.translateCode,
  });

  final String displayName;
  final String ocrCode;
  final String translateCode;

  factory LanguageInfo.fromJson(Map<String, dynamic> json) {
    return LanguageInfo(
      displayName: json['display_name'] as String,
      ocrCode: json['ocr_code'] as String,
      translateCode: json['translate_code'] as String,
    );
  }
}

class ProcessResult {
  ProcessResult({
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
      imageFormat: json['image_format'] as String? ?? 'png',
      accuracy: (json['accuracy'] as num).toDouble(),
      processingTimeSeconds: (json['processing_time_seconds'] as num).toDouble(),
    );
  }
}

class JobStatus {
  JobStatus({
    required this.jobId,
    required this.status,
    this.result,
    this.error,
  });

  final String jobId;
  final String status;
  final ProcessResult? result;
  final String? error;

  factory JobStatus.fromJson(Map<String, dynamic> json) {
    final resultJson = json['result'];
    return JobStatus(
      jobId: json['job_id'] as String,
      status: json['status'] as String,
      result: resultJson is Map<String, dynamic> ? ProcessResult.fromJson(resultJson) : null,
      error: json['error'] as String?,
    );
  }
}
