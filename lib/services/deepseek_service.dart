import 'dart:convert';
import 'package:http/http.dart' as http;
import '../providers/obd_state.dart';

class DeepSeekResponse {
  final String textResponse;
  final String? destination;

  DeepSeekResponse({
    required this.textResponse,
    this.destination,
  });
}

class DeepSeekService {
  Future<DeepSeekResponse> queryCopilot(
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
      final response = await http.post(
        Uri.parse('https://api.deepseek.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': 'deepseek-chat',
          'messages': [
            {'role': 'system', 'content': systemInstruction},
            {'role': 'system', 'content': 'Current Vehicle Telematics:\n$vehicleInfo'},
            {'role': 'user', 'content': userQuery},
          ],
          'response_format': {'type': 'json_object'},
          'temperature': 0.7,
        }),
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final content = decoded['choices'][0]['message']['content'].toString().trim();
        final jsonResponse = jsonDecode(content);

        final textResponse = jsonResponse['response']?.toString() ?? "";
        final dest = jsonResponse['destination']?.toString();
        
        return DeepSeekResponse(
          textResponse: textResponse,
          destination: (dest == null || dest.toLowerCase() == 'null' || dest.trim().isEmpty) ? null : dest,
        );
      } else {
        return DeepSeekResponse(
          textResponse: isThai 
              ? "เชื่อมต่อระบบ DeepSeek ไม่สำเร็จ (รหัสสถานะ: ${response.statusCode})"
              : "Failed to connect to DeepSeek (Status: ${response.statusCode})",
        );
      }
    } catch (e) {
      return DeepSeekResponse(
        textResponse: isThai 
            ? "เกิดข้อผิดพลาดในการเชื่อมต่อ: $e" 
            : "Connection error occurred: $e",
      );
    }
  }
}
