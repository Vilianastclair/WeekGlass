import 'package:flutter/material.dart';

/// A single absolute corner radius for every rounded rectangular surface.
abstract final class WeekGlassGeometry {
  static const radius = 12.0;
  static const corners = BorderRadius.all(Radius.circular(radius));
  static const shape = RoundedRectangleBorder(borderRadius: corners);
}
