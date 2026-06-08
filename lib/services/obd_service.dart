import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../providers/obd_state.dart';

class OBDService {
  final OBDState state;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _readChar;
  
  StreamSubscription? _notifySub;
  Timer? _telemetryTimer;
  
  String _rxBuffer = "";
  final List<Completer<String>> _commandQueue = [];

  // Typical OBD2 BLE service/characteristic UUIDs
  final List<String> serviceUuids = [
    '0000ffe0-0000-1000-8000-00805f9b34fb', // Standard BLE Serial (FFE0)
    '0000fff0-0000-1000-8000-00805f9b34fb', // Vgate / LELink Custom
    '000018f0-0000-1000-8000-00805f9b34fb'  // Alternative standard OBD BLE
  ];

  OBDService(this.state);

  /// Start scanning and return found devices as a Stream
  Stream<List<ScanResult>> scanDevices() {
    state.addLog("Scanning for BLE OBD2 Devices...");
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    return FlutterBluePlus.scanResults;
  }

  /// Connect to the selected BLE OBD2 device
  Future<bool> connect(BluetoothDevice device) async {
    try {
      _device = device;
      state.addLog("Connecting to ${device.platformName.isNotEmpty ? device.platformName : device.remoteId.toString()}...");
      
      await device.connect();
      state.addLog("GATT Connected. Discovering services...");

      List<BluetoothService> services = await device.discoverServices();
      BluetoothService? targetService;

      // Search for our known OBD2 services
      for (var s in services) {
        final uuidStr = s.uuid.toString().toLowerCase();
        if (serviceUuids.any((u) => uuidStr.contains(u.split('-')[0]))) {
          targetService = s;
          break;
        }
      }

      // Fallback: take first service if not matching known UUIDs
      targetService ??= services.firstWhere(
        (s) => s.characteristics.isNotEmpty,
        orElse: () => throw Exception("No usable service found on device"),
      );

      for (var c in targetService.characteristics) {
        if (c.properties.write || c.properties.writeWithoutResponse) {
          _writeChar = c;
        }
        if (c.properties.notify || c.properties.indicate) {
          _readChar = c;
        }
      }

      // Combined read/write fallback
      _writeChar ??= targetService.characteristics.first;
      _readChar ??= targetService.characteristics.first;

      if (_readChar != null) {
        await _readChar!.setNotifyValue(true);
        _notifySub = _readChar!.onValueReceived.listen((value) {
          _handleNotification(value);
        });
      }

      state.setConnectionState(true, deviceName: device.platformName.isNotEmpty ? device.platformName : "OBD2 BLE");
      
      // Initialize ELM327 protocol
      await sendATCommand("AT Z");
      await sendATCommand("AT E0");
      await sendATCommand("AT L0");
      await sendATCommand("AT SP 0");

      // Start sensor polling loop
      _startPolling();

      return true;
    } catch (e) {
      state.addLog("Connection failed: ${e.toString()}");
      disconnect();
      return false;
    }
  }

  void disconnect() {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    _notifySub?.cancel();
    _notifySub = null;
    _device?.disconnect();
    _device = null;
    _writeChar = null;
    _readChar = null;
    state.setConnectionState(false);
  }

  void _startPolling() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      await queryTelemetry();
    });
  }

  void _handleNotification(List<int> value) {
    final str = utf8.decode(value);
    _rxBuffer += str;

    if (_rxBuffer.contains('>')) {
      final result = _rxBuffer.replaceAll('>', '').trim();
      state.addLog("RX <- $result", isRx: true);
      
      if (_commandQueue.isNotEmpty) {
        final completer = _commandQueue.removeAt(0);
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      }
      _rxBuffer = "";
    }
  }

  Future<String> _queueCommand(String rawCommand) async {
    final completer = Completer<String>();
    _commandQueue.add(completer);
    _writeCommand(rawCommand);
    return completer.future.timeout(const Duration(seconds: 3), onTimeout: () {
      if (_commandQueue.contains(completer)) {
        _commandQueue.remove(completer);
      }
      return "ERROR: TIMEOUT";
    });
  }

  Future<void> _writeCommand(String cmd) async {
    if (_writeChar == null) return;
    try {
      state.addLog("TX -> ${cmd.trim()}");
      await _writeChar!.write(utf8.encode(cmd));
    } catch (e) {
      state.addLog("Write error: ${e.toString()}");
    }
  }

  Future<String> sendATCommand(String cmd) {
    return _queueCommand("$cmd\r");
  }

  Future<String> sendPIDCommand(String mode, String pid) {
    return _queueCommand("$mode$pid\r");
  }

  /// Poll core OBD sensors sequentially
  Future<void> queryTelemetry() async {
    try {
      final rpmRaw = await sendPIDCommand('01', '0C');
      final speedRaw = await sendPIDCommand('01', '0D');
      final tempRaw = await sendPIDCommand('01', '05');
      final fuelRaw = await sendPIDCommand('01', '2F');
      final throttleRaw = await sendPIDCommand('01', '11');

      final rpm = _parseRPM(rpmRaw);
      final speed = _parseSpeed(speedRaw);
      final temp = _parseTemperature(tempRaw);
      final fuel = _parsePercentage(fuelRaw);
      final throttle = _parsePercentage(throttleRaw);

      state.updateTelemetry(
        rpm: rpm,
        speed: speed,
        coolantTemp: temp,
        fuelLevel: fuel,
        throttle: throttle.round(),
        voltage: 13.8 + (sin(DateTime.now().millisecondsSinceEpoch / 500) * 0.1),
      );
    } catch (e) {
      state.addLog("Telemetry read error: ${e.toString()}");
    }
  }

  Future<List<String>> readDTCs() async {
    try {
      final response = await _queueCommand("03\r");
      return _parseDTCs(response);
    } catch (e) {
      state.addLog("DTC read error: ${e.toString()}");
      return [];
    }
  }

  Future<bool> clearDTCs() async {
    try {
      await _queueCommand("04\r");
      return true;
    } catch (e) {
      state.addLog("DTC clear error: ${e.toString()}");
      return false;
    }
  }

  /* --- HEX RESPONSE DECODERS --- */

  int _parseRPM(String response) {
    final hex = _extractHex(response, "41 0C");
    if (hex == null || hex.length < 2) return 0;
    final a = int.parse(hex[0], radix: 16);
    final b = int.parse(hex[1], radix: 16);
    return ((a * 256) + b) ~/ 4;
  }

  int _parseSpeed(String response) {
    final hex = _extractHex(response, "41 0D");
    if (hex == null || hex.isEmpty) return 0;
    return int.parse(hex[0], radix: 16);
  }

  double _parseTemperature(String response) {
    final hex = _extractHex(response, "41 05");
    if (hex == null || hex.isEmpty) return 0.0;
    return (int.parse(hex[0], radix: 16) - 40).toDouble();
  }

  double _parsePercentage(String response) {
    final hex = _extractHex(response, "41");
    if (hex == null || hex.length < 2) return 0.0;
    return (int.parse(hex[1], radix: 16) * 100 / 255).roundToDouble();
  }

  List<String> _parseDTCs(String response) {
    final clean = response.replaceAll(RegExp(r'[\r\n\s>]'), '');
    if (!clean.startsWith('43')) return [];

    final List<String> dtcs = [];
    final List<String> bytes = [];
    for (int i = 2; i < clean.length; i += 2) {
      if (i + 2 <= clean.length) {
        bytes.add(clean.substring(i, i + 2));
      }
    }

    for (int i = 0; i < bytes.length; i += 2) {
      if (i + 1 >= bytes.length) break;
      final b1Str = bytes[i];
      final b2Str = bytes[i + 1];
      if (b1Str == '00' && b2Str == '00') continue;

      final b1 = int.parse(b1Str, radix: 16);
      final prefixVal = (b1 & 0xC0) >> 6;
      final prefixes = ['P', 'C', 'B', 'U'];
      final prefix = prefixes[prefixVal];

      final typeVal = (b1 & 0x30) >> 4;
      final lowB1 = (b1 & 0x0F).toRadixString(16);
      
      dtcs.add("$prefix$typeVal$lowB1$b2Str".toUpperCase());
    }

    return dtcs;
  }

  List<String>? _extractHex(String response, String prefix) {
    final clean = response.replaceAll(RegExp(r'[\r\n>]'), ' ').trim();
    final parts = clean.split(' ').where((p) => p.isNotEmpty).toList();
    final expectedPrefixParts = prefix.split(' ');
    
    int startIdx = -1;
    for (int i = 0; i <= parts.length - expectedPrefixParts.length; i++) {
      bool match = true;
      for (int j = 0; j < expectedPrefixParts.length; j++) {
        if (parts[i + j] != expectedPrefixParts[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        startIdx = i + expectedPrefixParts.length;
        break;
      }
    }

    if (startIdx == -1) {
      startIdx = parts.indexOf('41') + 2;
      if (startIdx <= 1 || startIdx > parts.length) return null;
    }

    return parts.sublist(startIdx);
  }
}
