import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import '../providers/obd_state.dart';
import './map_service.dart';

class VoiceAssistantResponse {
  final String textResponse;
  final String destination;
  final double initialBattery;
  final double finalBattery;
  final double distanceKm;
  final double durationHrs;
  final double estimatedCost;
  final List<Map<String, String>> recommendedStops;

  VoiceAssistantResponse({
    required this.textResponse,
    required this.destination,
    required this.initialBattery,
    required this.finalBattery,
    required this.distanceKm,
    required this.durationHrs,
    required this.estimatedCost,
    required this.recommendedStops,
  });
}

class VoiceAssistantService {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isSpeaking = false;

  bool get isSpeaking => _isSpeaking;

  VoiceAssistantService() {
    _initTts();
  }

  void _initTts() async {
    try {
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setSpeechRate(0.55);
      await _flutterTts.setPitch(1.0);
      _flutterTts.setStartHandler(() {
        _isSpeaking = true;
      });
      _flutterTts.setCompletionHandler(() {
        _isSpeaking = false;
      });
      _flutterTts.setErrorHandler((msg) {
        _isSpeaking = false;
      });
    } catch (e) {
      // Ignore initialization errors
    }
  }

  Future<void> speak(String text, String langCode) async {
    try {
      await _flutterTts.stop();
      if (langCode == 'th') {
        await _flutterTts.setLanguage("th-TH");
      } else {
        await _flutterTts.setLanguage("en-US");
      }
      await _flutterTts.speak(text);
    } catch (e) {
      // TTS failure fallback
      _isSpeaking = false;
    }
  }

  Future<void> stop() async {
    try {
      await _flutterTts.stop();
      _isSpeaking = false;
    } catch (e) {
      // Ignore
    }
  }

  String parseDestinationName(String query, String langCode) {
    final lowerQuery = query.toLowerCase();
    String destination = "";
    final thaiRegex = RegExp(r'(?:ไป|เดินทางไป)\s*([a-zA-Z0-9ก-๙\s\.\,\-]+)');
    final engRegex = RegExp(r'(?:go to|navigate to|to)\s*([a-zA-Z0-9\s\.\,\-]+)');

    var match = thaiRegex.firstMatch(query);
    if (match != null) {
      destination = match.group(1)!.trim();
    } else {
      match = engRegex.firstMatch(lowerQuery);
      if (match != null) {
        destination = match.group(1)!.trim();
      } else {
        destination = query
            .replaceAll(RegExp(r'(?:แบต|เหลือ|battery|soc|\d+%)', caseSensitive: false), '')
            .replaceAll(RegExp(r'[.,!?]'), '')
            .trim();
      }
    }

    if (destination.isEmpty) {
      destination = langCode == 'th' ? "พัทยา" : "Pattaya";
    }
    return destination;
  }

  /// Parses the user's speech command asynchronously and generates a real-world route-based response.
  Future<VoiceAssistantResponse> parseCommand(
    String query,
    String langCode,
    MapService mapService,
    OBDState state,
  ) async {
    final lowerQuery = query.toLowerCase();
    
    // 1. Parse Battery/Fuel level (default to current level from state if none parsed)
    double battery = state.fuelLevel;
    final batteryRegex = RegExp(r'(\d+)\s*%');
    final matchBat = batteryRegex.firstMatch(lowerQuery);
    if (matchBat != null) {
      battery = double.tryParse(matchBat.group(1)!) ?? state.fuelLevel;
    } else {
      final numberRegex = RegExp(r'\b(\d+)\b');
      final matches = numberRegex.allMatches(lowerQuery);
      for (var m in matches) {
        final val = double.tryParse(m.group(1)!) ?? 0.0;
        if (val > 0 && val <= 100 && (lowerQuery.contains('แบต') || lowerQuery.contains('เหลือ') || lowerQuery.contains('bat') || lowerQuery.contains('soc') || lowerQuery.contains('%'))) {
          battery = val;
          break;
        }
      }
    }

    // 2. Parse Destination name
    String destination = "";
    final thaiRegex = RegExp(r'(?:ไป|เดินทางไป)\s*([a-zA-Z0-9ก-๙\s\.\,\-]+)');
    final engRegex = RegExp(r'(?:go to|navigate to|to)\s*([a-zA-Z0-9\s\.\,\-]+)');

    var match = thaiRegex.firstMatch(query);
    if (match != null) {
      destination = match.group(1)!.trim();
    } else {
      match = engRegex.firstMatch(lowerQuery);
      if (match != null) {
        destination = match.group(1)!.trim();
      } else {
        // Fallback: strip battery info and common helper words
        destination = query
            .replaceAll(RegExp(r'(?:แบต|เหลือ|battery|soc|\d+%)', caseSensitive: false), '')
            .replaceAll(RegExp(r'[.,!?]'), '')
            .trim();
      }
    }

    if (destination.isEmpty) {
      destination = langCode == 'th' ? "พัทยา" : "Pattaya";
    }

    state.addLog("AI Voice Assistant: Geocoding $destination...");
    final destLoc = await mapService.asyncGeocode(destination);

    if (destLoc == null) {
      final textResponse = langCode == 'th' 
          ? "ขออภัยด้วยค่ะ ไม่พบข้อมูลพิกัดของ $destination กรุณาลองระบุชื่อสถานที่ใหม่อีกครั้งค่ะ"
          : "Sorry, I couldn't find coordinates for $destination. Please try another location.";
      return VoiceAssistantResponse(
        textResponse: textResponse,
        destination: destination,
        initialBattery: battery,
        finalBattery: battery,
        distanceKm: 0.0,
        durationHrs: 0.0,
        estimatedCost: 0.0,
        recommendedStops: [],
      );
    }

    final double destLat = destLoc['latitude'];
    final double destLng = destLoc['longitude'];
    final String cleanDestName = destLoc['name'];

    // Start coordinates defaults to Bangkok Center
    final startLoc = {
      'name': 'Bangkok',
      'latitude': 13.7563,
      'longitude': 100.5018,
    };

    double distanceKm = 1.0;
    double durationHrs = 0.1;

    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/${startLoc['longitude']},${startLoc['latitude']};$destLng,$destLat?overview=false',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 'Ok' && data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final double distanceMeters = double.parse(route['distance'].toString());
          final double durationSeconds = double.parse(route['duration'].toString());
          distanceKm = distanceMeters / 1000.0;
          durationHrs = durationSeconds / 3600.0;
        }
      }
    } catch (e) {
      // Fallback distance estimation
      distanceKm = 140.0;
      durationHrs = 1.8;
    }

    // 3. SoC/Fuel and cost calculations based on vehicle profiles
    final isEv = state.vehicleType == VehicleType.ev;
    double finalBattery = battery;
    double cost = 0.0;
    List<Map<String, String>> stops = [];

    if (isEv) {
      final double totalWhNeeded = distanceKm * state.evEfficiency;
      final double batteryKwh = state.batteryCapacity;
      final double percentUsed = (totalWhNeeded / 1000.0 / batteryKwh) * 100.0;
      finalBattery = battery - percentUsed;
      cost = state.getEstimatedTripCost(VehicleType.ev, distanceKm * 1000.0);

      if (finalBattery < 15.0) {
        final double safeDistance = ((battery - 15.0) / 100.0) * (batteryKwh * 1000.0 / state.evEfficiency);
        stops.add({
          "name": "PTT EV Station (${safeDistance > 10 ? safeDistance.round() : 50} km)",
          "type": "120 kW CCS2 Supercharger"
        });
        finalBattery = 35.0; // simulated state post-charge
      }
    } else {
      final double litersNeeded = distanceKm / state.iceEfficiency;
      final double percentUsed = (litersNeeded / state.fuelTankCapacity) * 100.0;
      finalBattery = battery - percentUsed;
      cost = state.getEstimatedTripCost(VehicleType.ice, distanceKm * 1000.0);

      if (finalBattery < 15.0) {
        stops.add({
          "name": "PTT Gas Station",
          "type": "Refuel Stop"
        });
        finalBattery = 85.0;
      }
    }

    finalBattery = finalBattery.clamp(0.0, 100.0);

    String textResponse = "";
    if (langCode == 'th') {
      if (isEv) {
        textResponse = "ระยะทางไป $cleanDestName ประมาณ ${distanceKm.toStringAsFixed(1)} กิโลเมตร ใช้เวลาประมาณ ${durationHrs.toStringAsFixed(1)} ชั่วโมง แบตเตอรี่ปัจจุบัน $battery% คาดว่าถึงจุดหมายจะเหลือประมาณ ${finalBattery.round()}% ${stops.isNotEmpty ? 'แนะนำแวะชาร์จที่ ' + stops.first['name']! + ' ค่ะ' : 'แบตเตอรี่เพียงพอสำหรับเดินทางตรงได้เลยค่ะ'}";
      } else {
        textResponse = "ระยะทางไป $cleanDestName ประมาณ ${distanceKm.toStringAsFixed(1)} กิโลเมตร ใช้เวลาประมาณ ${durationHrs.toStringAsFixed(1)} ชั่วโมง ระดับน้ำมัน $battery% คาดว่าถึงปลายทางจะเหลือประมาณ ${finalBattery.round()}% ${stops.isNotEmpty ? 'แนะนำแวะเติมน้ำมันที่ ' + stops.first['name']! + ' ค่ะ' : 'น้ำมันเพียงพอสำหรับเดินทางได้โดยตรงค่ะ'}";
      }
    } else {
      if (isEv) {
        textResponse = "Distance to $cleanDestName is ${distanceKm.toStringAsFixed(1)} km, taking ${durationHrs.toStringAsFixed(1)} hours. Starting SoC is $battery%, and arrival SoC is estimated at ${finalBattery.round()}%. ${stops.isNotEmpty ? 'We recommend charging at ' + stops.first['name']! + '.' : 'You can reach it directly.'}";
      } else {
        textResponse = "Distance to $cleanDestName is ${distanceKm.toStringAsFixed(1)} km, taking ${durationHrs.toStringAsFixed(1)} hours. Starting fuel is $battery%, and arrival fuel is estimated at ${finalBattery.round()}%. ${stops.isNotEmpty ? 'We recommend refueling at ' + stops.first['name']! + '.' : 'You can reach it directly.'}";
      }
    }

    return VoiceAssistantResponse(
      textResponse: textResponse,
      destination: cleanDestName,
      initialBattery: battery,
      finalBattery: finalBattery,
      distanceKm: distanceKm,
      durationHrs: durationHrs,
      estimatedCost: cost,
      recommendedStops: stops,
    );
  }
}
