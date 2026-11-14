DateTime mondayOf(DateTime date) {
  final dayOffset = (date.weekday - DateTime.monday) % 7;
  final localDate = DateTime(date.year, date.month, date.day);
  return localDate.subtract(Duration(days: dayOffset));
}

List<DateTime> daysOfWeek(DateTime date) {
  final monday = mondayOf(date);
  return List<DateTime>.generate(
    7,
    (index) => monday.add(Duration(days: index)),
    growable: false,
  );
}

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String dateOnlyKey(DateTime value) {
  final date = dateOnly(value);
  return date.year.toString().padLeft(4, '0') +
      '-' +
      date.month.toString().padLeft(2, '0') +
      '-' +
      date.day.toString().padLeft(2, '0');
}

DateTime snapToMinutes(DateTime value, int interval) {
  final total = value.hour * 60 + value.minute;
  final snapped = ((total / interval).round() * interval).clamp(0, 1439);
  return DateTime(
    value.year,
    value.month,
    value.day,
    snapped ~/ 60,
    snapped % 60,
  );
}
