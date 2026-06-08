import 'dart:math';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum VehicleType { ev, ice }

class OBDState with ChangeNotifier {
  // Constructor
  OBDState() {
    _loadVehicleProfile();
  }

  // Vehicle Powertrain Type
  VehicleType _vehicleType = VehicleType.ev;
  VehicleType get vehicleType => _vehicleType;

  void setVehicleType(VehicleType type) {
    _vehicleType = type;
    _saveVehicleProfile();
    resetTrip();
    notifyListeners();
  }

  // Customizable EV Profile Details
  double _batteryCapacity = 60.0; // kWh
  double _evEfficiency = 150.0;   // Wh/km
  String _chargingPlug = "CCS2";

  double get batteryCapacity => _batteryCapacity;
  double get evEfficiency => _evEfficiency;
  String get chargingPlug => _chargingPlug;

  void setBatteryCapacity(double val) {
    _batteryCapacity = val;
    _saveVehicleProfile();
    notifyListeners();
  }

  void setEvEfficiency(double val) {
    _evEfficiency = val;
    _saveVehicleProfile();
    notifyListeners();
  }

  void setChargingPlug(String val) {
    _chargingPlug = val;
    _saveVehicleProfile();
    notifyListeners();
  }

  // Customizable ICE Profile Details
  double _fuelTankCapacity = 50.0; // Liters
  double _iceEfficiency = 14.0;    // km/L
  String _fuelType = "Gasohol 95";

  double get fuelTankCapacity => _fuelTankCapacity;
  double get iceEfficiency => _iceEfficiency;
  String get fuelType => _fuelType;

  void setFuelTankCapacity(double val) {
    _fuelTankCapacity = val;
    _saveVehicleProfile();
    notifyListeners();
  }

  void setIceEfficiency(double val) {
    _iceEfficiency = val;
    _saveVehicleProfile();
    notifyListeners();
  }

  void setFuelType(String val) {
    _fuelType = val;
    _saveVehicleProfile();
    notifyListeners();
  }

  Future<void> _loadVehicleProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _vehicleType = VehicleType.values[prefs.getInt('vehicle_type') ?? 0];
      _batteryCapacity = prefs.getDouble('battery_capacity') ?? 60.0;
      _evEfficiency = prefs.getDouble('ev_efficiency') ?? 150.0;
      _chargingPlug = prefs.getString('charging_plug') ?? "CCS2";
      _fuelTankCapacity = prefs.getDouble('fuel_tank_capacity') ?? 50.0;
      _iceEfficiency = prefs.getDouble('ice_efficiency') ?? 14.0;
      _fuelType = prefs.getString('fuel_type') ?? "Gasohol 95";
      _language = prefs.getString('language') ?? "en";
      notifyListeners();
    } catch (e) {
      // Ignore read errors
    }
  }

  Future<void> _saveVehicleProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('vehicle_type', _vehicleType.index);
      await prefs.setDouble('battery_capacity', _batteryCapacity);
      await prefs.setDouble('ev_efficiency', _evEfficiency);
      await prefs.setString('charging_plug', _chargingPlug);
      await prefs.setDouble('fuel_tank_capacity', _fuelTankCapacity);
      await prefs.setDouble('ice_efficiency', _iceEfficiency);
      await prefs.setString('fuel_type', _fuelType);
      await prefs.setString('language', _language);
    } catch (e) {
      // Ignore write errors
    }
  }

  void resetProfileToDefaults() {
    _batteryCapacity = 60.0;
    _evEfficiency = 150.0;
    _chargingPlug = "CCS2";
    _fuelTankCapacity = 50.0;
    _iceEfficiency = 14.0;
    _fuelType = "Gasohol 95";
    _saveVehicleProfile();
    resetTrip();
    notifyListeners();
  }

  // Cost and Carbon calculations
  double getEstimatedTripCost(VehicleType type, double distanceMeters) {
    final km = distanceMeters / 1000.0;
    if (type == VehicleType.ev) {
      // electricity: ~6.5 Baht per kWh
      return (km * _evEfficiency / 1000.0) * 6.5;
    } else {
      // fuel: E.g., Gasohol 95 avg price 38.5 Baht per liter
      double pricePerLiter = 38.5;
      if (_fuelType == "E20") {
        pricePerLiter = 36.2;
      } else if (_fuelType == "E85") {
        pricePerLiter = 34.0;
      } else if (_fuelType == "Diesel") {
        pricePerLiter = 33.0;
      }
      return (km / _iceEfficiency) * pricePerLiter;
    }
  }

  double getEstimatedTripCO2(VehicleType type, double distanceMeters) {
    final km = distanceMeters / 1000.0;
    if (type == VehicleType.ev) {
      // Indirect grid emissions: ~0.50 kg CO2 / kWh
      return (km * _evEfficiency / 1000.0) * 0.50;
    } else {
      // Direct tailpipe emissions: ~2.3 kg CO2 per liter of gasoline combusted
      double co2PerLiter = 2.3;
      if (_fuelType == "Diesel") co2PerLiter = 2.68; // diesel has higher carbon density
      return (km / _iceEfficiency) * co2PerLiter;
    }
  }

  // Telemetry metrics (Shared & EV specific)
  int _rpm = 0; // Motor or Engine RPM
  int _speed = 0; // Vehicle Speed (km/h)
  double _coolantTemp = 30.0; // Battery Pack or Engine Coolant Temp (°C)
  double _fuelLevel = 100.0; // SoC (EV) or Gas Fuel Level (ICE) %
  int _throttle = 0; // Accelerator Pedal %
  double _voltage = 396.0; // Traction Battery Voltage (EV) or Accessory/12V (ICE)
  double _powerUsage = 0.0; // Power Flow (kW) (+ Discharge, - Regen)

  int get rpm => _rpm;
  int get speed => _speed;
  double get coolantTemp => _coolantTemp;
  double get fuelLevel => _fuelLevel;
  int get throttle => _throttle;
  double get voltage => _voltage;
  double get powerUsage => _powerUsage;

  // ICE specific metrics
  double _engineLoad = 0.0; // Engine Load %
  double _fuelFlowRate = 0.0; // Fuel Flow Rate L/h
  double _sparkAdvance = 15.0; // Ignition timing
  final List<double> _fuelFlowHistory = [];
  final List<double> _cylinderFuelTrims = List.generate(4, (index) => 0.0);

  double get engineLoad => _engineLoad;
  double get fuelFlowRate => _fuelFlowRate;
  double get sparkAdvance => _sparkAdvance;
  List<double> get fuelFlowHistory => _fuelFlowHistory;
  List<double> get cylinderFuelTrims => _cylinderFuelTrims;

  // EV Getters for readable code
  double get batteryLevel => _fuelLevel;
  double get batteryTemp => _coolantTemp;
  double get batteryVoltage => _voltage;

  // EV Advanced Telemetry History
  final List<double> _powerHistory = [];
  List<double> get powerHistory => _powerHistory;

  final List<double> _cellVoltages = List.generate(96, (index) => 4.12);
  List<double> get cellVoltages => _cellVoltages;

  bool _isCharging = false;
  bool get isCharging => _isCharging;
  bool get isRefueling => _isCharging; // Fueling acts identical to charge state

  // Bilingual State (EN/TH)
  String _language = 'en';
  String get language => _language;

  void toggleLanguage() {
    _language = _language == 'en' ? 'th' : 'en';
    notifyListeners();
  }

  final Map<String, Map<String, String>> _localizedStrings = {
    'en': {
      'ev_status': 'EV POWERTRAIN STATUS',
      'battery_soc': 'Battery SoC',
      'speed': 'Speed',
      'power_flow': 'POWER FLOW',
      'motor_speed': 'MOTOR SPEED',
      'power_usage_flow': 'Power Usage Flow',
      'battery_temp': 'Battery Pack Temp',
      'accelerator': 'Accelerator Pedal',
      'logs': 'EV OBD2 ADAPTER LOGS',
      'diagnostics': 'DIAGNOSTICS & FAULTS',
      'healthy': 'System Healthy',
      'unhealthy': 'Check Engine Light',
      'no_faults': 'No Faults',
      'faults': 'Faults',
      'inject_error': 'Inject Error',
      'clear_codes': 'Clear Codes',
      'smart_logs': 'SMART TRIP LOGS',
      'instruction': 'NAVIGATION INSTRUCTION',
      'waiting_nav': 'Waiting for active navigation route...',
      'cell_balance': 'BATTERY CELL VOLTAGE BALANCE (96S)',
      'balanced': 'BALANCED (4.12V)',
      'unbalanced': 'WARNING: UNBALANCED CELL',
      'voltage_delta': 'Max delta: 12mV',
      'cell_fault': 'Cell 43: Low voltage detected (3.25V)',
      'route_here': 'Route Here',
      'plug_charge': 'Plug & Charge',
      'dc_charging': 'DC FAST CHARGING ACTIVE',
      'charging_speed': 'CHARGING SPEED',
      'voltage_current': 'VOLTAGE & CURRENT',
      'added_energy': 'ADDED ENERGY',
      'added_range': 'ADDED RANGE',
      'est_cost': 'EST. COST',
      'start_sim': 'Start Sim',
      'stop_sim': 'Stop Sim',
      'reset_trip': 'Reset Trip',
      'connect_obd': 'Connect OBD2',
      'simulator': 'Simulator',
      'telemetry_tab': 'Telemetry',
      'map_tab': 'Map Planner',
      'diag_tab': 'Diagnostics',
      'engine_active': 'EV Drive Engaged',
      'engine_idle': 'EV Parked',
      'low_bat_alert_title': 'Low Battery Warning',
      'low_bat_alert_msg': 'Battery level is below 15%. Find a charging station soon.',
      'bat_overheat_title': 'Battery Overheating',
      'bat_overheat_msg': 'Battery pack temperature too high: %s! Power limited.',
      'speed_limit_title': 'Speed Advisory',
      'speed_limit_msg': 'Vehicle is exceeding 110 km/h highway speed suggestion.',
      'disconnect': 'Disconnect',
      'connect_ble': 'Connect BLE',
      'disable_sim': 'Disable Sim',
      'enable_sim': 'Enable Sim',
      'route_planner': 'ROUTE PLANNER',
      'start_point': 'Start Point',
      'destination': 'Destination',
      'get_directions': 'Get Directions',
      'distance': 'DISTANCE',
      'est_duration': 'EST. DURATION',
      'pause': 'Pause',
      'drive': 'Drive',
      'waiting_telemetry': 'Waiting for powertrain telemetry...',
      'live_energy_flow': 'LIVE ENERGY FLOW (kW)',
      'select_adapter': 'Select OBD2 BLE Adapter',
      'select_adapter_desc': 'Choose an OBD2 adapter to connect. (If BLE is disabled or fails, it triggers pairing simulation).',
      'cancel': 'Cancel',
      'clear_dtcs': 'Clear DTCs',
      // ICE Specific
      'ice_status': 'ICE ENGINE STATUS',
      'fuel_level': 'Fuel Level',
      'fuel_flow': 'FUEL FLOW RATE',
      'engine_load': 'Engine Load',
      'coolant_temp_ice': 'Engine Coolant Temp',
      'live_fuel_flow': 'LIVE FUEL FLOW (L/h)',
      'cylinder_trim': 'CYLINDER FUEL TRIM & SPARK TIMING',
      'balanced_ice': 'CYLINDERS BALANCED',
      'unbalanced_ice': 'WARNING: UNBALANCED CYLINDER',
      'spark_adv': 'Spark Advance',
      'cylinder_fault': 'Cylinder 2: High fuel trim deviation detected (-12.5%)',
      'refuel_here': 'Refuel Here',
      'start_refueling': 'Start Refueling',
      'refueling_active': 'REFUELING ACTIVE',
      'refuel_speed': 'REFUEL SPEED',
      'added_fuel': 'ADDED FUEL',
      'added_fuel_range': 'ADDED RANGE',
      'est_fuel_cost': 'EST. COST',
      'waiting_telemetry_ice': 'Waiting for engine telemetry...',
      'engine_active_ice': 'Engine Running',
      'engine_idle_ice': 'Engine Stopped',
      'low_fuel_alert_title': 'Low Fuel Warning',
      'low_fuel_alert_msg': 'Fuel level is below 15%. Find a gas station soon.',
      'engine_overheat_title': 'Engine Overheating',
      'engine_overheat_msg': 'Engine coolant temperature too high: %s! Check coolant level.',
      // Profile Settings
      'vehicle_profile': 'VEHICLE PROFILE',
      'battery_cap': 'Battery Capacity',
      'ev_efficiency': 'EV Efficiency',
      'plug_type': 'Charging Plug',
      'tank_size': 'Fuel Tank Size',
      'fuel_efficiency': 'Fuel Efficiency',
      'fuel_type': 'Fuel Type',
      'eco_comparison': 'TRIP ECO COMPARISON',
      'running_cost': 'Est. Running Cost',
      'co2_emissions': 'Est. CO2 Emissions',
      'you_save': 'TOTAL SAVINGS WITH EV',
      'electricity_cost': 'Electricity Cost',
      'fuel_cost': 'Fuel Cost',
      'spec_sheet': 'VEHICLE SPEC SHEET',
      'reset_profile': 'Reset Profile',
      'save_profile': 'Profile Saved',
      'voice_copilot': 'AI Voice Copilot',
      'mic_prompt': 'Say something like: "Go to Chiang Mai with 65% battery"',
      'listening': 'Listening...',
      'thinking': 'AI is calculating route and chargers...',
      'ask_copilot': 'Ask AI Copilot',
      'start_nav': 'Start Trip',
      'suggested_stops': 'Suggested Charging Stops',
      'presets': 'Preset Commands',
      'copilot_speech_desc': 'Ask the copilot in Thai or English to plan your route and charging automatically.',
    },
    'th': {
      'ev_status': 'สถานะขุมพลัง EV',
      'battery_soc': 'สถานะแบตเตอรี่ (SoC)',
      'speed': 'ความเร็ว',
      'power_flow': 'การไหลเวียนพลังงาน',
      'motor_speed': 'ความเร็วรอบมอเตอร์',
      'power_usage_flow': 'อัตราการใช้พลังงาน',
      'battery_temp': 'อุณหภูมิแบตเตอรี่',
      'accelerator': 'ระดับการเหยียบคันเร่ง',
      'logs': 'บันทึกการส่งข้อมูล OBD2',
      'diagnostics': 'การวิเคราะห์และรหัสปัญหา',
      'healthy': 'ระบบทำงานปกติ',
      'unhealthy': 'ไฟแจ้งเตือนระบบขัดข้อง',
      'no_faults': 'ปกติ ไม่มีรหัสข้อบกพร่อง',
      'faults': 'ข้อบกพร่อง',
      'inject_error': 'จำลองโค้ดปัญหา',
      'clear_codes': 'ล้างโค้ดปัญหา',
      'smart_logs': 'บันทึกการขับขี่อัจฉริยะ',
      'instruction': 'คำแนะนำการนำทาง',
      'waiting_nav': 'กำลังรอการนำทาง...',
      'cell_balance': 'ความสมดุลแรงดันเซลล์แบตเตอรี่ (96S)',
      'balanced': 'สมดุลปกติ (4.12V)',
      'unbalanced': 'คำเตือน: เซลล์ไม่สมดุล',
      'voltage_delta': 'ความต่างสูงสุด: 12mV',
      'cell_fault': 'เซลล์ที่ 43: ตรวจพบแรงดันต่ำ (3.25V)',
      'route_here': 'นำทางมาตู้ชาร์จนี้',
      'plug_charge': 'เริ่มเสียบชาร์จ',
      'dc_charging': 'กำลังชาร์จด่วน DC Fast Charge',
      'charging_speed': 'ความเร็วการชาร์จ',
      'voltage_current': 'แรงดันและกระแสไฟ',
      'added_energy': 'พลังงานไฟฟ้าที่ได้รับ',
      'added_range': 'ระยะทางที่เพิ่มขึ้น',
      'est_cost': 'ประเมินค่าไฟฟ้า',
      'start_sim': 'เริ่มจำลอง',
      'stop_sim': 'หยุดจำลอง',
      'reset_trip': 'รีเซ็ตข้อมูล',
      'connect_obd': 'เชื่อมต่อ OBD2',
      'simulator': 'โหมดจำลอง',
      'telemetry_tab': 'แผงควบคุม',
      'map_tab': 'แผนที่นำทาง',
      'diag_tab': 'วิเคราะห์รถ',
      'engine_active': 'กำลังขับเคลื่อนรถ',
      'engine_idle': 'จอดหยุดนิ่ง',
      'low_bat_alert_title': 'เตือนแบตเตอรี่ต่ำ',
      'low_bat_alert_msg': 'ระดับแบตเตอรี่ต่ำกว่า 15% กรุณาชาร์จไฟด่วน',
      'bat_overheat_title': 'แบตเตอรี่ร้อนเกินไป',
      'bat_overheat_msg': 'อุณหภูมิชุดแบตเตอรี่สูงเกินไป: %s! จำกัดกำลังไฟฟ้า',
      'speed_limit_title': 'เตือนจำกัดความเร็ว',
      'speed_limit_msg': 'ความเร็วเกิน 110 กม./ชม. โปรดใช้ความระมัดระวัง',
      'disconnect': 'ตัดการเชื่อมต่อ',
      'connect_ble': 'เชื่อมต่อ BLE',
      'disable_sim': 'ปิดจำลอง',
      'enable_sim': 'เปิดจำลอง',
      'route_planner': 'วางแผนเส้นทาง',
      'start_point': 'จุดเริ่มต้น',
      'destination': 'จุดหมายปลายทาง',
      'get_directions': 'ค้นหาเส้นทาง',
      'distance': 'ระยะทาง',
      'est_duration': 'เวลาโดยประมาณ',
      'pause': 'หยุดชั่วคราว',
      'drive': 'เริ่มขับ',
      'waiting_telemetry': 'กำลังรอข้อมูลระบบขับเคลื่อน...',
      'live_energy_flow': 'กราฟพลังงานเรียลไทม์ (kW)',
      'select_adapter': 'เลือกตัวแปลง OBD2 BLE',
      'select_adapter_desc': 'เลือกตัวแปลง OBD2 เพื่อเชื่อมต่อ (หากปิดใช้งาน BLE หรือล้มเหลว จะเริ่มการจำลองการจับคู่)',
      'cancel': 'ยกเลิก',
      'clear_dtcs': 'ล้างโค้ด DTC',
      // ICE Specific
      'ice_status': 'สถานะเครื่องยนต์เบนซิน',
      'fuel_level': 'ระดับน้ำมันเชื้อเพลิง',
      'fuel_flow': 'อัตราการจ่ายน้ำมัน',
      'engine_load': 'ภาระเครื่องยนต์',
      'coolant_temp_ice': 'อุณหภูมิน้ำหล่อเย็นเครื่องยนต์',
      'live_fuel_flow': 'อัตราการจ่ายน้ำมัน (ลิตร/ชม.)',
      'cylinder_trim': 'อัตราจ่ายน้ำมันสูบและองศาจุดระเบิด',
      'balanced_ice': 'การจ่ายน้ำมันแต่ละสูบปกติ',
      'unbalanced_ice': 'คำเตือน: จ่ายน้ำมันไม่สมดุล',
      'spark_adv': 'องศาจุดระเบิด',
      'cylinder_fault': 'สูบที่ 2: ตรวจพบค่าเบี่ยงเบนน้ำมันสูง (-12.5%)',
      'refuel_here': 'นำทางไปปั๊มน้ำมันนี้',
      'start_refueling': 'เริ่มเติมน้ำมัน',
      'refueling_active': 'กำลังเติมน้ำมันเชื้อเพลิง',
      'refuel_speed': 'ความเร็วในการเติมน้ำมัน',
      'added_fuel': 'น้ำมันที่เติมเข้าไป',
      'added_fuel_range': 'ระยะทางที่เพิ่มขึ้น',
      'est_fuel_cost': 'ประเมินค่าน้ำมัน',
      'waiting_telemetry_ice': 'กำลังรอข้อมูลเครื่องยนต์...',
      'engine_active_ice': 'เครื่องยนต์กำลังทำงาน',
      'engine_idle_ice': 'ดับเครื่องยนต์',
      'low_fuel_alert_title': 'เตือนน้ำมันใกล้หมด',
      'low_fuel_alert_msg': 'ระดับน้ำมันต่ำกว่า 15% กรุณาเติมน้ำมันด่วน',
      'engine_overheat_title': 'เครื่องยนต์ร้อนเกินไป',
      'engine_overheat_msg': 'อุณหภูมิน้ำหล่อเย็นสูงเกินไป: %s! โปรดตรวจสอบระดับน้ำหล่อเย็น',
      // Profile Settings
      'vehicle_profile': 'โปรไฟล์รถยนต์',
      'battery_cap': 'ความจุแบตเตอรี่',
      'ev_efficiency': 'อัตรากินไฟรถ EV',
      'plug_type': 'ประเภทหัวชาร์จ',
      'tank_size': 'ความจุถังน้ำมัน',
      'fuel_efficiency': 'อัตราประหยัดน้ำมัน',
      'fuel_type': 'ประเภทน้ำมัน',
      'eco_comparison': 'เปรียบเทียบค่าใช้จ่ายและมลพิษ',
      'running_cost': 'ประมาณการค่าเดินทาง',
      'co2_emissions': 'การปล่อยก๊าซ CO2',
      'you_save': 'ประหยัดได้ทั้งหมด (เมื่อใช้ EV)',
      'electricity_cost': 'ค่าชาร์จไฟฟ้า',
      'fuel_cost': 'ค่าน้ำมันเชื้อเพลิง',
      'spec_sheet': 'ข้อมูลจำเพาะรถยนต์',
      'reset_profile': 'รีเซ็ตโปรไฟล์',
      'save_profile': 'บันทึกโปรไฟล์เรียบร้อย',
      'voice_copilot': 'ผู้ช่วยนำทาง AI',
      'mic_prompt': 'ลองพูด: "ไปเขาหลวง ตาก แบตเหลือ 60%"',
      'listening': 'กำลังฟัง...',
      'thinking': 'AI กำลังวิเคราะห์เส้นทางและสถานีชาร์จ...',
      'ask_copilot': 'คุยกับ AI Copilot',
      'start_nav': 'เริ่มเดินทาง',
      'suggested_stops': 'สถานีชาร์จที่แนะนำ',
      'presets': 'คำสั่งแนะนำ',
      'copilot_speech_desc': 'สั่งการด้วยเสียงภาษาไทยหรือภาษาอังกฤษเพื่อวางแผนการเดินทางและจุดชาร์จแบบอัตโนมัติ',
    }
  };

  String text(String key) {
    return _localizedStrings[_language]?[key] ?? key;
  }

  // Connection modes
  bool _isConnected = false;
  bool _isSimulatorMode = true;
  String _connectionName = "DISCONNECTED";

  bool get isConnected => _isConnected;
  bool get isSimulatorMode => _isSimulatorMode;
  String get connectionName => _connectionName;

  // Diagnostic Trouble Codes (DTCs)
  final List<Map<String, String>> _activeDtcList = [];
  List<Map<String, String>> get activeDtcList => _activeDtcList;

  // Navigation states
  List<LatLng> _routePoints = [];
  List<Map<String, dynamic>> _routeSteps = [];
  double _totalDistance = 0.0; // meters
  double _totalDuration = 0.0; // seconds
  double _remainingDistance = 0.0;
  LatLng? _vehiclePosition;
  int _currentCoordIndex = 0;

  List<LatLng> get routePoints => _routePoints;
  List<Map<String, dynamic>> get routeSteps => _routeSteps;
  double get totalDistance => _totalDistance;
  double get totalDuration => _totalDuration;
  double get remainingDistance => _remainingDistance;
  LatLng? get vehiclePosition => _vehiclePosition;
  int get currentCoordIndex => _currentCoordIndex;

  // Simulation parameters
  bool _isDriving = false;
  int _simulationSpeed = 1;

  bool get isDriving => _isDriving;
  int get simulationSpeed => _simulationSpeed;

  // Log Streams & Alerts
  final List<String> _consoleLogs = ["System idle. Connect OBD2 or toggle Simulator to begin."];
  final List<Map<String, dynamic>> _alertList = [
    {
      "title": "EV Ready",
      "message": "Plan your route or connect to OBD2 to start monitoring EV metrics.",
      "type": "info",
      "time": "Just Now"
    }
  ];

  List<String> get consoleLogs => _consoleLogs;
  List<Map<String, dynamic>> get alertList => _alertList;

  // UI Threshold Checkers (anti-spam triggers)
  bool _alertLowFuel = false;
  bool _alertHighTemp = false;
  bool _alertSpeedLimit = false;

  void addLog(String msg, {bool isRx = false}) {
    // Fallback if context unavailable
    final finalTime = DateTime.now().toLocal().toString().split(' ')[1].substring(0, 8);
    final prefix = isRx ? '◀ ' : '▶ ';
    _consoleLogs.add("[$finalTime] $prefix$msg");
    if (_consoleLogs.length > 50) {
      _consoleLogs.removeAt(0);
    }
    notifyListeners();
  }

  void addAlert(String title, String message, String type) {
    final finalTime = DateTime.now().toLocal().toString().split(' ')[1].substring(0, 5);
    _alertList.insert(0, {
      "title": title,
      "message": message,
      "type": type,
      "time": finalTime,
    });
    if (_alertList.length > 30) {
      _alertList.removeLast();
    }
    notifyListeners();
  }

  void setCharging(bool value) {
    _isCharging = value;
    if (_vehicleType == VehicleType.ev) {
      if (value) {
        addLog("DC Fast Charger connected.");
        addAlert("Charging Initiated", "Connected to CCS2 120kW Fast Charger.", "info");
      } else {
        addLog("DC Fast Charger disconnected.");
        addAlert("Charging Stopped", "CCS2 Charger disconnected.", "info");
      }
    } else {
      if (value) {
        addLog("Gas pump nozzle inserted.");
        addAlert("Charging Initiated", "Connected to fuel pump nozzle. Fueling active.", "info");
      } else {
        addLog("Gas pump nozzle removed.");
        addAlert("Charging Stopped", "Gas pump nozzle removed.", "info");
      }
    }
    notifyListeners();
  }

  void updateTelemetry({
    required int rpm,
    required int speed,
    required double coolantTemp,
    required double fuelLevel,
    required int throttle,
    required double voltage,
    double powerUsage = 0.0,
    double fuelFlowRate = 0.0,
    double engineLoad = 0.0,
    double sparkAdvance = 15.0,
  }) {
    _rpm = rpm;
    _speed = speed;
    _coolantTemp = coolantTemp;
    _fuelLevel = fuelLevel;
    _throttle = throttle;
    _voltage = voltage;
    _powerUsage = powerUsage;
    _fuelFlowRate = fuelFlowRate;
    _engineLoad = engineLoad;
    _sparkAdvance = sparkAdvance;

    if (_vehicleType == VehicleType.ev) {
      _powerHistory.add(_powerUsage);
      if (_powerHistory.length > 50) {
        _powerHistory.removeAt(0);
      }

      // Dynamic cell voltages balance
      final hasCellFailure = _activeDtcList.any((dtc) => dtc['code'] == 'P0A80');
      final ms = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < 96; i++) {
        if (hasCellFailure && i == 42) {
          _cellVoltages[i] = 3.25 + (sin(ms / 1000) * 0.02);
        } else {
          // Normal cell balance with slight noise
          _cellVoltages[i] = 4.12 + (sin(i / 10 + ms / 8000) * 0.012);
        }
      }
    } else {
      _fuelFlowHistory.add(_fuelFlowRate);
      if (_fuelFlowHistory.length > 50) {
        _fuelFlowHistory.removeAt(0);
      }

      // Dynamic cylinder fuel trims balance
      final hasMisfire = _activeDtcList.any((dtc) => dtc['code'] == 'P0302');
      final ms = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < 4; i++) {
        if (hasMisfire && i == 1) { // Cylinder 2 misfire
          _cylinderFuelTrims[i] = -12.5 + (sin(ms / 500) * 1.5);
        } else {
          _cylinderFuelTrims[i] = 0.2 + (sin(i * 1.2 + ms / 3000) * 0.8);
        }
      }
    }

    // Check smart alert thresholds
    _checkTelemetryThresholds();
    notifyListeners();
  }

  void _checkTelemetryThresholds() {
    if (_vehicleType == VehicleType.ev) {
      // Low Battery SoC
      if (_fuelLevel < 15 && !_alertLowFuel) {
        _alertLowFuel = true;
        addAlert("Low Battery Warning", "Battery level is below 15%. Find a charging station soon.", "danger");
      } else if (_fuelLevel >= 15) {
        _alertLowFuel = false;
      }

      // High Battery Temp
      if (_coolantTemp > 55 && !_alertHighTemp) {
        _alertHighTemp = true;
        addAlert("Battery Overheating", "Battery pack temperature too high: ${_coolantTemp.toStringAsFixed(1)}°C! Power limited.", "danger");
      } else if (_coolantTemp <= 55) {
        _alertHighTemp = false;
      }
    } else {
      // Low Fuel
      if (_fuelLevel < 15 && !_alertLowFuel) {
        _alertLowFuel = true;
        addAlert("Low Fuel Warning", "Fuel level is below 15%. Find a gas station soon.", "danger");
      } else if (_fuelLevel >= 15) {
        _alertLowFuel = false;
      }

      // High Engine Temp
      if (_coolantTemp > 105 && !_alertHighTemp) {
        _alertHighTemp = true;
        addAlert("Engine Overheating", "Engine coolant temperature too high: ${_coolantTemp.toStringAsFixed(1)}°C! Check coolant levels.", "danger");
      } else if (_coolantTemp <= 105) {
        _alertHighTemp = false;
      }
    }

    // Speed Warning
    if (_speed > 110 && !_alertSpeedLimit) {
      _alertSpeedLimit = true;
      addAlert("Speed Advisory", "Vehicle is exceeding 110 km/h highway speed suggestion.", "warning");
    } else if (_speed <= 110) {
      _alertSpeedLimit = false;
    }
  }

  void setConnectionMode({required bool simulator}) {
    _isSimulatorMode = simulator;
    if (_isSimulatorMode) {
      _isConnected = false;
      _connectionName = "SIMULATOR ACTIVE";
      addLog("Simulator mode enabled.");
    } else {
      _connectionName = "DISCONNECTED";
      addLog("Simulator deactivated. Pair Bluetooth OBD2 device.");
    }
    notifyListeners();
  }

  void setConnectionState(bool connected, {String deviceName = "DISCONNECTED"}) {
    _isConnected = connected;
    if (connected) {
      _isSimulatorMode = false;
      _connectionName = "CONNECTED ($deviceName)";
      addLog("BLE OBD2 Connected. Reading live sensors.");
      addAlert("OBD2 Paired", "Successfully established connection to $deviceName.", "info");
    } else {
      _connectionName = "DISCONNECTED";
      addLog("BLE OBD2 Disconnected.");
    }
    notifyListeners();
  }

  void updateRoute(List<LatLng> points, List<Map<String, dynamic>> steps, double distance, double duration) {
    _routePoints = points;
    _routeSteps = steps;
    _totalDistance = distance;
    _totalDuration = duration;
    _remainingDistance = distance;
    _currentCoordIndex = 0;
    if (points.isNotEmpty) {
      _vehiclePosition = points[0];
    }
    addLog("Route updated. Total: ${(distance / 1000).toStringAsFixed(1)} km.");
    addAlert("Route Planned", "New route path generated successfully.", "info");
    notifyListeners();
  }

  void updateVehiclePosition(int coordIndex, double remaining, LatLng position) {
    _currentCoordIndex = coordIndex;
    _remainingDistance = remaining;
    _vehiclePosition = position;
    notifyListeners();
  }

  void setDrivingState(bool driving) {
    _isDriving = driving;
    if (driving) {
      addAlert("Engine Active", "Vehicle initiated driving simulation.", "info");
    } else {
      addAlert("Engine Idle", "Driving simulation paused.", "info");
    }
    notifyListeners();
  }

  void setSimulationSpeed(int speed) {
    _simulationSpeed = speed;
    addLog("Simulation speed set to x$speed");
    notifyListeners();
  }

  void injectDtc(String code, String desc) {
    final alreadyExists = _activeDtcList.any((dtc) => dtc['code'] == code);
    if (!alreadyExists) {
      _activeDtcList.add({"code": code, "desc": desc});
      addLog("OBD2 Fault Registered: $code");
      addAlert("DTC Active: $code", "MIL active: $desc. Service vehicle soon.", "danger");
      notifyListeners();
    }
  }

  void clearDtcs() {
    if (_activeDtcList.isNotEmpty) {
      _activeDtcList.clear();
      addLog("TX -> 04");
      addLog("RX <- Clear Codes Acknowledged", isRx: true);
      addAlert("DTC Cleared", "Engine fault codes cleared successfully. MIL deactivated.", "info");
      notifyListeners();
    }
  }

  void resetTrip() {
    _currentCoordIndex = 0;
    _remainingDistance = _totalDistance;
    _isDriving = false;
    if (_routePoints.isNotEmpty) {
      _vehiclePosition = _routePoints[0];
    }
    _fuelLevel = 100.0;
    _coolantTemp = _vehicleType == VehicleType.ev ? 30.0 : 85.0;
    _speed = 0;
    _rpm = 0;
    _powerUsage = 0.0;
    _fuelFlowRate = 0.0;
    _engineLoad = 0.0;
    _isCharging = false;
    _powerHistory.clear();
    _fuelFlowHistory.clear();

    addLog("Trip simulator reset.");
    if (_vehicleType == VehicleType.ev) {
      addAlert("Simulation Reset", "Vehicle returned to start and battery fully recharged.", "info");
    } else {
      addAlert("Simulation Reset", "Vehicle returned to start and fuel tank fully refilled.", "info");
    }
    notifyListeners();
  }

  void setFuelLevelDirect(double level) {
    _fuelLevel = level.clamp(0.0, 100.0);
    _alertLowFuel = false;
    notifyListeners();
  }
}
