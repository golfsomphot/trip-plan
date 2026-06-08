import 'dart:convert';
import 'package:http/http.dart' as http;
import '../providers/obd_state.dart';

class GeminiResponse {
  final String textResponse;
  final String? destination;

  GeminiResponse({
    required this.textResponse,
    this.destination,
  });
}

class GeminiService {
  Future<GeminiResponse> queryCopilot(
    String userQuery,
    String langCode,
    OBDState state,
    String apiKey,
  ) async {
    final isThai = langCode == 'th';
    final vehicleInfo = '''
Current Vehicle Status:
- Powertrain: ${state.vehicleType == VehicleType.ev ? 'Electric Vehicle (EV)' : 'Gasoline (ICE)'}
- Battery/Fuel level: ${state.fuelLevel.round()}%
- Average consumption: ${state.vehicleType == VehicleType.ev ? '${state.evEfficiency} Wh/km' : '${state.iceEfficiency} km/L'}
- Battery/Tank Size: ${state.vehicleType == VehicleType.ev ? '${state.batteryCapacity} kWh' : '${state.fuelTankCapacity} L'}
- Charging Plug type: ${state.chargingPlug}
''';

    final systemInstruction = '''
You are the AI copilot "SomPhot", integrated with the driver's vehicle OBD-II telematics data.
Answer the user's query concisely and dynamically based on the current vehicle status provided.

Return your response strictly in the following JSON format:
{
  "response": "Your spoken reply/advice here",
  "destination": "Name of the destination city or location if the user wants to navigate there, otherwise null"
}
''';

    try {
      final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$apiKey');
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          "contents": [
            {
              "role": "user",
              "parts": [
                {"text": systemInstruction},
                {"text": "Current Vehicle Telematics:\n$vehicleInfo"},
                {"text": "User Query: $userQuery"}
              ]
            }
          ],
          "generationConfig": {
            "responseMimeType": "application/json"
          }
        }),
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final content = decoded['candidates'][0]['content']['parts'][0]['text'].toString().trim();
        final jsonResponse = jsonDecode(content);

        final textResponse = jsonResponse['response']?.toString() ?? "";
        final dest = jsonResponse['destination']?.toString();
        
        return GeminiResponse(
          textResponse: textResponse,
          destination: (dest == null || dest.toLowerCase() == 'null' || dest.trim().isEmpty) ? null : dest,
        );
      } else {
        return GeminiResponse(
          textResponse: isThai 
              ? "เชื่อมต่อระบบ Gemini ไม่สำเร็จ (รหัสสถานะ: ${response.statusCode})"
              : "Failed to connect to Gemini (Status: ${response.statusCode})",
        );
      }
    } catch (e) {
      return GeminiResponse(
        textResponse: isThai 
            ? "เกิดข้อผิดพลาดในการเชื่อมต่อ: $e" 
            : "Connection error occurred: $e",
      );
    }
  }
}
