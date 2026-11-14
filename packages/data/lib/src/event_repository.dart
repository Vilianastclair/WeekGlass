import 'package:weekglass_domain/weekglass_domain.dart';

abstract interface class EventRepository {
  Future<List<CalendarEvent>> getAllEvents();

  Future<List<CalendarEvent>> getEventsForRange({
    required DateTime startLocal,
    required DateTime endLocal,
  });

  Future<void> save(CalendarEvent event);
  Future<void> saveBatch(List<CalendarEvent> events);
  Future<void> deleteBatch(List<String> ids);

  Future<void> delete(String id);

  Future<void> close();
}

/// Includes tombstones so repeated imports respect locally deleted courses.
abstract interface class ImportedEventRepository {
  Future<List<CalendarEvent>> getImportedEvents(String sourcePrefix);
}
