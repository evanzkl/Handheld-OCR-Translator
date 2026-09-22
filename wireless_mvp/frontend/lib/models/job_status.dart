import 'process_result.dart';

/// Status of an ESP32 capture job created via POST /api/v1/jobs.
class JobStatus {
  JobStatus({required this.jobId, required this.status, this.result, this.error});

  final String jobId;
  final String status; // pending | done | error
  final ProcessResult? result;
  final String? error;

  factory JobStatus.fromJson(Map<String, dynamic> json) {
    return JobStatus(
      jobId: json['job_id'] as String,
      status: json['status'] as String,
      result: json['result'] == null
          ? null
          : ProcessResult.fromJson(json['result'] as Map<String, dynamic>),
      error: json['error'] as String?,
    );
  }
}
