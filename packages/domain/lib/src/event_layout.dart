import 'calendar_event.dart';

class EventLaneLayout {
  const EventLaneLayout({required this.laneIndex, required this.laneCount});

  final int laneIndex;
  final int laneCount;

  double get leftFraction => laneIndex / laneCount;
  double get widthFraction => 1 / laneCount;
}

/// Computes deterministic horizontal lanes for connected overlap clusters.
/// Intervals use [start, end) semantics: adjacent events do not overlap.
Map<String, EventLaneLayout> layoutTimedEvents(List<CalendarEvent> events) {
  final sorted = events.where((event) => !event.isAllDay).toList()
    ..sort((a, b) {
      final byStart = a.startLocal.compareTo(b.startLocal);
      if (byStart != 0) return byStart;
      return a.endLocal.compareTo(b.endLocal);
    });

  final result = <String, EventLaneLayout>{};
  var cluster = <CalendarEvent>[];
  var clusterEnd = DateTime.fromMillisecondsSinceEpoch(0);

  void flush() {
    if (cluster.isEmpty) return;
    final laneEnds = <DateTime>[];
    final assigned = <(String, int)>[];

    for (final event in cluster) {
      var lane = laneEnds.indexWhere((end) => !end.isAfter(event.startLocal));
      if (lane < 0) {
        lane = laneEnds.length;
        laneEnds.add(event.endLocal);
      } else {
        laneEnds[lane] = event.endLocal;
      }
      assigned.add((event.id, lane));
    }

    final laneCount = laneEnds.length;
    for (final assignment in assigned) {
      result[assignment.$1] = EventLaneLayout(
        laneIndex: assignment.$2,
        laneCount: laneCount,
      );
    }
    cluster = <CalendarEvent>[];
    clusterEnd = DateTime.fromMillisecondsSinceEpoch(0);
  }

  for (final event in sorted) {
    if (cluster.isNotEmpty && !event.startLocal.isBefore(clusterEnd)) {
      flush();
    }
    cluster.add(event);
    if (event.endLocal.isAfter(clusterEnd)) {
      clusterEnd = event.endLocal;
    }
  }
  flush();
  return result;
}
