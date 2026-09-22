/// A language option shared by the source/target dropdowns.
///
/// Field names mirror the JSON returned by `GET /api/languages`.
class Language {
  const Language({
    required this.displayName,
    required this.ocrCode,
    required this.translateCode,
  });

  final String displayName;
  final String ocrCode;
  final String translateCode;

  factory Language.fromJson(Map<String, dynamic> json) {
    return Language(
      displayName: json['display_name'] as String,
      ocrCode: json['ocr_code'] as String,
      translateCode: json['translate_code'] as String,
    );
  }
}
