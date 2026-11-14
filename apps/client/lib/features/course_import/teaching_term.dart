/// School term and confirmed teaching calendar; contains no account data.
class TeachingTerm {
  const TeachingTerm({
    required this.year,
    required this.semester,
    required this.firstMonday,
    required this.weeks,
  });
  final int year, semester, weeks;
  final DateTime firstMonday;
  String get key => '$year-$semester';
  int get number => switch (semester) {
    3 => 1,
    12 => 2,
    _ => 3,
  };
  bool get valid =>
      year >= 2000 &&
      year <= 2100 &&
      const [3, 12, 16].contains(semester) &&
      weeks >= 1 &&
      weeks <= 53 &&
      firstMonday.weekday == DateTime.monday &&
      firstMonday.year >= year &&
      firstMonday.year <= year + 1;

  int? weekAt(DateTime date) {
    final offset = DateTime.utc(date.year, date.month, date.day)
        .difference(
          DateTime.utc(firstMonday.year, firstMonday.month, firstMonday.day),
        )
        .inDays;
    if (offset < 0 || offset >= weeks * 7) return null;
    return offset ~/ 7 + 1;
  }

  Map<String, Object> toJson() => {
    'year': year,
    'semester': semester,
    'firstMonday': firstMonday.toIso8601String(),
    'weeks': weeks,
  };
  factory TeachingTerm.fromJson(Map<String, dynamic> value) => TeachingTerm(
    year: value['year'] as int,
    semester: value['semester'] as int,
    firstMonday: DateTime.parse(value['firstMonday'] as String),
    weeks: value['weeks'] as int,
  );
}
