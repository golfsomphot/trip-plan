import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../providers/obd_state.dart';
import 'obd_simulator.dart';

class MapService {
  final OBDState state;
  Timer? _driveTimer;
  int _coordIndex = 0;

  MapService(this.state);

  /// Geocode location names using Nominatim geocoding API
  asyncGeocode(String query) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(query)}&limit=1',
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'DriveSyncFlutterOBD2/1.0',
      });

      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        if (data.isNotEmpty) {
          final first = data[0];
          return {
            'name': first['display_name'].toString().split(',')[0],
            'latitude': double.parse(first['lat']),
            'longitude': double.parse(first['lon']),
          };
        }
      }
    } catch (e) {
      state.addLog("Geocode error: ${e.toString()}");
    }
    return null;
  }

  /// Calculate route using Open Source Routing Machine (OSRM) API
  Future<bool> calculateRoute(Map<String, dynamic> start, Map<String, dynamic> dest) async {
    try {
      final startLat = start['latitude'];
      final startLng = start['longitude'];
      final destLat = dest['latitude'];
      final destLng = dest['longitude'];

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$startLng,$startLat;$destLng,$destLat?overview=full&geometries=geojson&steps=true',
      );

      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 'Ok' && data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final double distance = double.parse(route['distance'].toString()); // meters
          final double duration = double.parse(route['duration'].toString()); // seconds

          // Extract coordinates [lng, lat] and map to LatLng(lat, lng)
          final List coords = route['geometry']['coordinates'];
          final List<LatLng> points = coords.map<LatLng>((c) => LatLng(c[1], c[0])).toList();

          // Extract steps
          final List stepsRaw = route['legs'][0]['steps'];
          final List<Map<String, dynamic>> steps = stepsRaw.map<Map<String, dynamic>>((s) {
            final loc = s['maneuver']['location'];
            return {
              'instruction': s['maneuver']['instruction'].toString(),
              'distance': double.parse(s['distance'].toString()),
              'name': s['name'].toString().isNotEmpty ? s['name'].toString() : "Road",
              'location': LatLng(loc[1], loc[0])
            };
          }).toList();

          state.updateRoute(points, steps, distance, duration);
          return true;
        }
      }
    } catch (e) {
      state.addLog("Routing error: ${e.toString()}");
    }
    return false;
  }

  /// Start simulation drive movement along the route points
  void startDriving(OBDSimulator simulator) {
    stopDriving();
    _coordIndex = state.currentCoordIndex;
    state.setDrivingState(true);

    _driveTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      _advanceVehicle(simulator);
    });
  }

  void stopDriving() {
    _driveTimer?.cancel();
    _driveTimer = null;
    state.setDrivingState(false);
  }

  void _advanceVehicle(OBDSimulator simulator) {
    final points = state.routePoints;
    if (points.isEmpty) return;

    // Advance based on speed multiplier
    _coordIndex += (1 * state.simulationSpeed);

    if (_coordIndex >= points.length) {
      _coordIndex = points.length - 1;
      state.updateVehiclePosition(_coordIndex, 0.0, points[_coordIndex]);
      stopDriving();
      simulator.setTargetSpeed(0.0);
      state.addLog("Arrived at destination.");
      state.addAlert("Trip Completed", "You have arrived at your destination!", "info");
      return;
    }

    final currentPos = points[_coordIndex];

    // Calculate remaining distance mathematically
    double remaining = 0.0;
    const distanceCalc = Distance();
    for (int i = _coordIndex; i < points.length - 1; i++) {
      remaining += distanceCalc.as(LengthUnit.Meter, points[i], points[i + 1]);
    }

    // Dynamic target speed calculation
    double targetSpeed = 80.0; // standard highway cruising
    final double progress = _coordIndex / points.length;

    if (progress < 0.05 || progress > 0.95) {
      targetSpeed = 30.0; // Slow near start or endpoint
    } else {
      // Curve checking
      if (_coordIndex > 1 && _coordIndex < points.length - 2) {
        final p1 = points[_coordIndex - 2];
        final p2 = points[_coordIndex];
        final p3 = points[_coordIndex + 2];
        
        final double angle = _getAngleBetweenPoints(p1, p2, p3);
        if (angle < 155) {
          targetSpeed = 40.0; // sharp turn
        } else if (angle > 175) {
          targetSpeed = 100.0; // highway straightaway
        }
      }
    }

    simulator.setTargetSpeed(targetSpeed);
    state.updateVehiclePosition(_coordIndex, remaining, currentPos);
  }

  double _getAngleBetweenPoints(LatLng p1, LatLng p2, LatLng p3) {
    // 2D angle approximation
    final double dx1 = p1.longitude - p2.longitude;
    final double dy1 = p1.latitude - p2.latitude;
    final double dx2 = p3.longitude - p2.longitude;
    final double dy2 = p3.latitude - p2.latitude;

    final double dot = dx1 * dx2 + dy1 * dy2;
    final double mag1 = sqrt(dx1 * dx1 + dy1 * dy1);
    final double mag2 = sqrt(dx2 * dx2 + dy2 * dy2);
    
    final double magProduct = mag1 * mag2;
    if (magProduct == 0.0) return 180.0;

    final double cosAngle = dot / magProduct;
    // clamp between -1 and 1
    final double clamped = cosAngle.clamp(-1.0, 1.0);
    return acos(clamped) * 180.0 / pi;
  }
}
