import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

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

  /// Parses the user's speech command and generates a structured voice/text response.
  VoiceAssistantResponse parseCommand(String query, String langCode) {
    final lowerQuery = query.toLowerCase();
    
    // Default values
    String destination = "Pattaya";
    double battery = 100.0;
    double finalBattery = 85.0;
    double distanceKm = 140.0;
    double durationHrs = 1.8;
    double cost = 120.0;
    List<Map<String, String>> stops = [];
    String textResponse = "";

    // 1. Parse Battery level (look for numbers followed by % or preceded by battery words)
    final batteryRegex = RegExp(r'(\d+)\s*%');
    final match = batteryRegex.firstMatch(lowerQuery);
    if (match != null) {
      battery = double.tryParse(match.group(1) ?? '100') ?? 100.0;
    } else {
      // Look for any isolated number
      final numberRegex = RegExp(r'\b(\d+)\b');
      final numMatches = numberRegex.allMatches(lowerQuery);
      for (var m in numMatches) {
        final val = double.tryParse(m.group(1) ?? '0') ?? 0;
        if (val > 5 && val <= 100 && (lowerQuery.contains('แบต') || lowerQuery.contains('เหลือ') || lowerQuery.contains('bat') || lowerQuery.contains('soc'))) {
          battery = val;
          break;
        }
      }
    }

    // 2. Parse Destination
    if (lowerQuery.contains("เขาหลวง") || lowerQuery.contains("ตาก") || lowerQuery.contains("tak") || lowerQuery.contains("khao luang")) {
      destination = "Khao Luang, Tak";
      distanceKm = 470.0;
      durationHrs = 5.5;
      
      if (battery >= 90) {
        finalBattery = 22.0;
        cost = 360.0;
        stops = [
          {"name": "PTT EV Station Kamphaeng Phet", "type": "120 kW CCS2"},
        ];
        if (langCode == 'th') {
          textResponse = "ระยะทางไปเขาหลวง ตาก ประมาณ 470 กิโลเมตร แบตเตอรี่ปัจจุบัน $battery% แนะนำแวะชาร์จที่ PTT EV Station กำแพงเพชร 15 นาที จะถึงจุดหมายปลายทางโดยเหลือแบตเตอรี่ประมาณ 22% ค่ะ";
        } else {
          textResponse = "Distance to Khao Luang, Tak is 470 kilometers. With $battery% battery, we recommend charging at PTT EV Station Kamphaeng Phet for 15 minutes. You will arrive with approximately 22% battery remaining.";
        }
      } else if (battery >= 50) {
        finalBattery = 15.0;
        cost = 490.0;
        stops = [
          {"name": "PTT EV Station Nakhon Sawan", "type": "120 kW CCS2"},
          {"name": "EA Anywhere Kamphaeng Phet", "type": "100 kW CCS2"},
        ];
        if (langCode == 'th') {
          textResponse = "ระยะทางไปเขาหลวง ตาก ประมาณ 470 กิโลเมตร แบตเตอรี่ปัจจุบัน $battery% แนะนำแวะชาร์จ 2 จุดที่ PTT นครสวรรค์ และ EA กำแพงเพชร รวม 35 นาที จะถึงจุดหมายโดยเหลือแบตเตอรี่ประมาณ 15% ค่ะ";
        } else {
          textResponse = "Distance to Khao Luang, Tak is 470 kilometers. With $battery% battery, we recommend charging at PTT Nakhon Sawan and EA Kamphaeng Phet for a total of 35 minutes. You will arrive with 15% battery remaining.";
        }
      } else {
        finalBattery = 12.0;
        cost = 580.0;
        stops = [
          {"name": "PEA VOLTA Sing Buri", "type": "120 kW CCS2"},
          {"name": "PTT EV Station Nakhon Sawan", "type": "120 kW CCS2"},
          {"name": "EA Anywhere Tak", "type": "100 kW CCS2"},
        ];
        if (langCode == 'th') {
          textResponse = "ระยะทางไปเขาหลวง ตาก ประมาณ 470 กิโลเมตร แบตเตอรี่ปัจจุบันน้อยเพียง $battery% แนะนำแวะชาร์จ 3 จุดที่ สิงห์บุรี, นครสวรรค์ และ ตาก รวม 50 นาที เพื่อความปลอดภัยในการเดินทางค่ะ";
        } else {
          textResponse = "Distance to Khao Luang, Tak is 470 kilometers. Your battery is low at $battery%. We recommend 3 charging stops at Sing Buri, Nakhon Sawan, and Tak for a total of 50 minutes to travel safely.";
        }
      }
    } else if (lowerQuery.contains("เชียงใหม่") || lowerQuery.contains("chiang mai")) {
      destination = "Chiang Mai";
      distanceKm = 690.0;
      durationHrs = 8.5;
      
      if (battery >= 80) {
        finalBattery = 18.0;
        cost = 680.0;
        stops = [
          {"name": "PTT EV Station Nakhon Sawan", "type": "150 kW CCS2"},
          {"name": "PEA VOLTA Lampang", "type": "120 kW CCS2"},
        ];
        if (langCode == 'th') {
          textResponse = "คำนวณเส้นทางไปเชียงใหม่ ระยะทาง 690 กิโลเมตร แนะนำชาร์จไฟที่ นครสวรรค์ และ ลำปาง รวม 40 นาที จะถึงปลายทางเหลือแบตเตอรี่ประมาณ 18% ค่ะ";
        } else {
          textResponse = "Route calculated to Chiang Mai, 690 kilometers. Recommend charging at Nakhon Sawan and Lampang for 40 minutes. You will arrive with 18% battery.";
        }
      } else {
        finalBattery = 14.0;
        cost = 820.0;
        stops = [
          {"name": "PEA VOLTA Sing Buri", "type": "120 kW CCS2"},
          {"name": "PTT EV Station Kamphaeng Phet", "type": "120 kW CCS2"},
          {"name": "PEA VOLTA Lampang", "type": "120 kW CCS2"},
        ];
        if (langCode == 'th') {
          textResponse = "คำนวณเส้นทางไปเชียงใหม่ ระยะทาง 690 กิโลเมตร แบตเตอรี่ปัจจุบัน $battery% แนะนำแวะชาร์จที่ สิงห์บุรี, กำแพงเพชร และ ลำปาง รวม 55 นาที จะถึงปลายทางเหลือแบตเตอรี่ 14% ค่ะ";
        } else {
          textResponse = "Route calculated to Chiang Mai, 690 kilometers with $battery% battery. Recommend charging at Sing Buri, Kamphaeng Phet, and Lampang for 55 minutes. Arrive with 14% battery.";
        }
      }
    } else {
      // Default to Pattaya
      destination = "Pattaya";
      distanceKm = 140.0;
      durationHrs = 1.8;
      
      if (battery >= 40) {
        finalBattery = battery - 32;
        cost = 90.0;
        stops = [];
        if (langCode == 'th') {
          textResponse = "ระยะทางไปพัทยา 140 กิโลเมตร แแบตเตอรี่ปัจจุบัน $battery% เพียงพอสำหรับเดินทางโดยไม่ต้องแวะชาร์จ จะถึงปลายทางโดยเหลือแบตเตอรี่ประมาณ ${finalBattery.round()}% ค่ะ";
        } else {
          textResponse = "Distance to Pattaya is 140 kilometers. With $battery% battery, you can reach it directly without charging. You will arrive with ${finalBattery.round()}% battery remaining.";
        }
      } else {
        finalBattery = 20.0;
        cost = 140.0;
        stops = [
          {"name": "PTT EV Station Chonburi Supercharge", "type": "150 kW CCS2"}
        ];
        if (langCode == 'th') {
          textResponse = "ระยะทางไปพัทยา 140 กิโลเมตร แบตเตอรี่ $battery% ไม่เพียงพอ แนะนำแวะชาร์จที่ PTT ชลบุรี 15 นาที จะถึงปลายทางเหลือแบตเตอรี่ประมาณ 20% ค่ะ";
        } else {
          textResponse = "Distance to Pattaya is 140 kilometers. Your battery of $battery% is insufficient. We recommend charging at PTT Chonburi for 15 minutes, arriving with 20% battery.";
        }
      }
    }

    return VoiceAssistantResponse(
      textResponse: textResponse,
      destination: destination,
      initialBattery: battery,
      finalBattery: finalBattery,
      distanceKm: distanceKm,
      durationHrs: durationHrs,
      estimatedCost: cost,
      recommendedStops: stops,
    );
  }
}
