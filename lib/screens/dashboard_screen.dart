import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import 'package:fl_chart/fl_chart.dart';

import '../providers/obd_state.dart';
import '../services/obd_simulator.dart';
import '../services/obd_service.dart';
import '../services/map_service.dart';
import '../services/voice_assistant_service.dart';
import '../widgets/gauge_painter.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _startController = TextEditingController(text: "Bangkok");
  final TextEditingController _destController = TextEditingController(text: "Pattaya");
  
  late OBDSimulator _simulator;
  late OBDService _obdService;
  late MapService _mapService;
  final VoiceAssistantService _voiceService = VoiceAssistantService();
  
  bool _isLoadingRoute = false;
  int _selectedIndex = 0;
  int _rightPanelTabIndex = 0;

  @override
  void initState() {
    super.initState();
    final state = Provider.of<OBDState>(context, listen: false);
    
    // Wire services
    _simulator = OBDSimulator(state);
    _obdService = OBDService(state);
    _mapService = MapService(state);
    
    // Start simulator in idle mode by default after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _simulator.start();
    });
  }

  @override
  void dispose() {
    _simulator.stop();
    _obdService.disconnect();
    _mapService.stopDriving();
    _voiceService.stop();
    _startController.dispose();
    _destController.dispose();
    super.dispose();
  }

  // Open mock/real BLE selector dialog
  void _showBleSelectionDialog(OBDState state) {
    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: Text(
            state.text('select_adapter'),
            style: const TextStyle(fontFamily: 'Space Grotesk', color: Colors.blueAccent, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: 320,
            height: 250,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.text('select_adapter_desc'),
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      _buildMockDeviceTile("Veepeak OBDCheck BLE", ctx, state),
                      _buildMockDeviceTile("Vgate iCar Pro BLE4.0", ctx, state),
                      _buildMockDeviceTile("LELink OBDII Bluetooth", ctx, state),
                    ],
                  ),
                )
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(state.text('cancel'), style: const TextStyle(color: Colors.black54)),
            )
          ],
        );
      },
    );
  }

  Widget _buildMockDeviceTile(String name, BuildContext dialogCtx, OBDState state) {
    return Card(
      color: Colors.grey[50],
      shape: RoundedRectangleBorder(side: BorderSide(color: Colors.black.withOpacity(0.08))),
      child: ListTile(
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
        subtitle: const Text("BLE Serial Passthrough", style: TextStyle(color: Colors.black54, fontSize: 11)),
        trailing: const Icon(Icons.bluetooth, color: Colors.blueAccent),
        onTap: () {
          Navigator.pop(dialogCtx);
          _mockBleConnectionFlow(name, state);
        },
      ),
    );
  }

  // Emulates BLE command notifications for platforms without physical OBDBLE support
  void _mockBleConnectionFlow(String deviceName, OBDState state) {
    _simulator.stop();
    _mapService.stopDriving();
    state.setConnectionMode(simulator: false);
    state.addLog("Initiating pairing wrapper with virtual $deviceName...");
    
    Future.delayed(const Duration(milliseconds: 1000), () {
      state.setConnectionState(true, deviceName: deviceName);
      state.addLog("TX -> AT Z");
      state.addLog("RX <- ELM327 v2.1", isRx: true);
      state.addLog("TX -> AT E0");
      state.addLog("RX <- OK", isRx: true);
      
      // Periodically update telemetry using mock polling
      Timer.periodic(const Duration(seconds: 1), (timer) {
        if (state.isConnected) {
          final mockSecs = DateTime.now().millisecondsSinceEpoch / 1000;
          final double throttle = 45 + sin(mockSecs / 2) * 15;
          final double speed = 80 + sin(mockSecs / 2.5) * 8;
          final double power = throttle * 1.1 - speed * 0.1;
          final double volt = 385.0 + sin(mockSecs / 5) * 2.0 - (power * 0.05);
          state.updateTelemetry(
            rpm: (speed * 80).round(),
            speed: speed.round(),
            coolantTemp: 38.0 + sin(mockSecs / 10) * 0.5,
            fuelLevel: max(0.0, 78.0 - (mockSecs / 800)),
            throttle: throttle.round(),
            voltage: double.parse(volt.toStringAsFixed(1)),
            powerUsage: double.parse(power.toStringAsFixed(1)),
          );
        } else {
          timer.cancel();
        }
      });
    });
  }

  // Calculate geocoding and routing
  Future<void> _onCalculateRoute(OBDState state) async {
    final startVal = _startController.text.trim();
    final destVal = _destController.text.trim();
    
    if (startVal.isEmpty || destVal.isEmpty) return;

    setState(() { _isLoadingRoute = true; });

    final startLoc = await _mapService.asyncGeocode(startVal);
    final destLoc = await _mapService.asyncGeocode(destVal);

    if (startLoc == null || destLoc == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.language == 'th' ? "ไม่พบพิกัดจุดเริ่มต้นหรือจุดหมายปลายทาง" : "Error geocoding start or destination location.")),
      );
      setState(() { _isLoadingRoute = false; });
      return;
    }

    final success = await _mapService.calculateRoute(startLoc, destLoc);
    setState(() { _isLoadingRoute = false; });

    if (success && state.routePoints.isNotEmpty) {
      _mapController.move(state.routePoints.first, 12);
    }
  }

  void _showVoiceAssistantDialog(OBDState state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return VoiceAssistantSheet(
          state: state,
          voiceService: _voiceService,
          onStartTrip: (response) {
            _startController.text = "Bangkok";
            _destController.text = response.destination;
            state.setFuelLevelDirect(response.initialBattery);
            _onCalculateRoute(state);
            if (!state.isSimulatorMode) {
              state.setConnectionMode(simulator: true);
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<OBDState>(context);
    final size = MediaQuery.of(context).size;

    // Responsive grid arrangement
    if (size.width > 1200) {
      return Scaffold(
        backgroundColor: const Color(0xFFF6F8FA),
        appBar: _buildAppBar(state),
        body: Row(
          children: [
            // Left Panel (Telemetry)
            SizedBox(
              width: 360,
              child: _buildTelemetryPanel(state),
            ),
            const VerticalDivider(width: 1, color: Colors.black12),
            
            // Map Panel
            Expanded(
              child: _buildMapPanel(state),
            ),
            const VerticalDivider(width: 1, color: Colors.black12),
            
            // Right Panel (Diagnostics / Vehicle Settings Tabbed View)
            SizedBox(
              width: 380,
              child: Container(
                color: Colors.white,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: Colors.black12, width: 1)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _rightPanelTabIndex = 0;
                                });
                              },
                              child: Container(
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: _rightPanelTabIndex == 0 ? Colors.blueAccent : Colors.transparent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  state.text('diag_tab').toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: _rightPanelTabIndex == 0 ? Colors.blueAccent : Colors.black54,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _rightPanelTabIndex = 1;
                                });
                              },
                              child: Container(
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: _rightPanelTabIndex == 1 ? Colors.blueAccent : Colors.transparent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  state.text('vehicle_profile').toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: _rightPanelTabIndex == 1 ? Colors.blueAccent : Colors.black54,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: _rightPanelTabIndex == 0
                            ? _buildDiagnosticsPanel(state)
                            : _buildVehicleProfilePanel(state),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // Tabbed layouts for mobile/tablets
      Widget activeBody;
      switch (_selectedIndex) {
        case 0:
          activeBody = SingleChildScrollView(
            child: _buildTelemetryPanel(state),
          );
          break;
        case 1:
          activeBody = _buildMapPanel(state);
          break;
        case 2:
          activeBody = SingleChildScrollView(
            child: _buildDiagnosticsPanel(state),
          );
          break;
        case 3:
          activeBody = SingleChildScrollView(
            child: _buildVehicleProfilePanel(state),
          );
          break;
        default:
          activeBody = _buildMapPanel(state);
      }

      return Scaffold(
        backgroundColor: const Color(0xFFF6F8FA),
        appBar: _buildAppBar(state),
        body: activeBody,
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          selectedItemColor: Colors.blueAccent,
          unselectedItemColor: Colors.grey[600],
          currentIndex: _selectedIndex,
          onTap: (index) {
            setState(() {
              _selectedIndex = index;
            });
          },
          items: [
            BottomNavigationBarItem(
              icon: const Icon(Icons.analytics),
              label: state.text('telemetry_tab'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.map),
              label: state.text('map_tab'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.battery_charging_full),
              label: state.text('diag_tab'),
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.drive_eta),
              label: state.text('vehicle_profile'),
            ),
          ],
        ),
      );
    }
  }

  PreferredSizeWidget _buildAppBar(OBDState state) {
    Color statusColor = Colors.grey;
    if (state.isConnected) {
      statusColor = Colors.green;
    } else if (state.isSimulatorMode) {
      statusColor = Colors.blueAccent;
    }

    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isMobile = screenWidth <= 800;

    Widget titleWidget;
    if (isMobile) {
      titleWidget = Row(
        children: [
          const Icon(Icons.speed, color: Colors.blueAccent, size: 20),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "DRIVESYNC",
                style: TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  fontSize: 14,
                  color: Colors.black87,
                ),
              ),
              Text(
                state.connectionName.toUpperCase(),
                style: TextStyle(
                  fontSize: 8,
                  color: statusColor,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      titleWidget = Row(
        children: [
          const Icon(Icons.speed, color: Colors.blueAccent),
          const SizedBox(width: 8),
          const Text(
            "DRIVESYNC",
            style: TextStyle(
              fontFamily: 'Space Grotesk',
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 18,
              color: Colors.black87,
            ),
          ),
          const SizedBox(width: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.04),
              border: Border.all(color: Colors.black.withOpacity(0.08)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  state.connectionName.toUpperCase(),
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: Colors.black87),
                ),
              ],
            ),
          )
        ],
      );
    }

    List<Widget> actionsList;
    if (isMobile) {
      actionsList = [
        IconButton(
          icon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.translate, size: 16, color: Colors.black87),
              const SizedBox(width: 2),
              Text(
                state.language.toUpperCase(),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ],
          ),
          onPressed: () => state.toggleLanguage(),
          tooltip: "Switch Language",
        ),
        IconButton(
          icon: Icon(
            state.vehicleType == VehicleType.ev ? Icons.electric_car : Icons.local_gas_station,
            color: state.vehicleType == VehicleType.ev ? Colors.green : Colors.orange,
            size: 18,
          ),
          onPressed: () {
            state.setVehicleType(
              state.vehicleType == VehicleType.ev ? VehicleType.ice : VehicleType.ev,
            );
            if (state.isSimulatorMode) {
              _simulator.start();
            }
          },
          tooltip: "Toggle Powertrain Profile",
        ),
        IconButton(
          icon: Icon(
            state.isConnected ? Icons.bluetooth_disabled : Icons.bluetooth,
            color: state.isConnected ? Colors.redAccent : Colors.blueAccent,
          ),
          onPressed: () {
            if (state.isConnected) {
              _obdService.disconnect();
            } else {
              _showBleSelectionDialog(state);
            }
          },
          tooltip: state.isConnected ? state.text('disconnect') : state.text('connect_ble'),
        ),
        IconButton(
          icon: Icon(
            state.isSimulatorMode ? Icons.developer_board : Icons.developer_board_off,
            color: state.isSimulatorMode ? Colors.blueAccent : Colors.black54,
          ),
          onPressed: () {
            state.setConnectionMode(simulator: !state.isSimulatorMode);
            if (state.isSimulatorMode) {
              _simulator.start();
            } else {
              _simulator.stop();
            }
          },
          tooltip: state.isSimulatorMode ? state.text('disable_sim') : state.text('enable_sim'),
        ),
      ];
    } else {
      actionsList = [
        IconButton(
          icon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.translate, size: 18, color: Colors.black87),
              const SizedBox(width: 4),
              Text(
                state.language.toUpperCase(),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ],
          ),
          onPressed: () => state.toggleLanguage(),
          tooltip: "Switch Language",
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[100],
              foregroundColor: Colors.black87,
              side: const BorderSide(color: Colors.black12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              state.setVehicleType(
                state.vehicleType == VehicleType.ev ? VehicleType.ice : VehicleType.ev,
              );
              if (state.isSimulatorMode) {
                _simulator.start();
              }
            },
            icon: Icon(
              state.vehicleType == VehicleType.ev ? Icons.electric_car : Icons.local_gas_station,
              size: 16,
              color: state.vehicleType == VehicleType.ev ? Colors.green : Colors.orange,
            ),
            label: Text(
              state.vehicleType == VehicleType.ev ? "EV" : "ICE",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: state.isConnected ? Colors.red.withOpacity(0.2) : Colors.blueAccent,
              foregroundColor: state.isConnected ? Colors.redAccent : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              if (state.isConnected) {
                _obdService.disconnect();
              } else {
                _showBleSelectionDialog(state);
              }
            },
            icon: Icon(state.isConnected ? Icons.bluetooth_disabled : Icons.bluetooth),
            label: Text(state.isConnected ? state.text('disconnect') : state.text('connect_ble'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: const BorderSide(color: Colors.black12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              state.setConnectionMode(simulator: !state.isSimulatorMode);
              if (state.isSimulatorMode) {
                _simulator.start();
              } else {
                _simulator.stop();
              }
            },
            child: Text(state.isSimulatorMode ? state.text('disable_sim') : state.text('enable_sim')),
          ),
        ),
      ];
    }

    return AppBar(
      backgroundColor: Colors.white,
      title: titleWidget,
      actions: actionsList,
    );
  }

  Widget _buildTelemetryPanel(OBDState state) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.isCharging) _buildChargingPanel(state),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                state.vehicleType == VehicleType.ev ? state.text('ev_status') : state.text('ice_status'),
                style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, letterSpacing: 1.0, color: Colors.black87),
              ),
              Text("${state.voltage.toStringAsFixed(1)}V", style: TextStyle(color: state.vehicleType == VehicleType.ev ? Colors.blueAccent : Colors.orange, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 16),
          // Circular Gauges Grid
          Row(
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: CustomPaint(
                    painter: GaugePainter(
                      value: state.fuelLevel,
                      maxVal: 100,
                      label: state.vehicleType == VehicleType.ev ? state.text('battery_soc') : state.text('fuel_level'),
                      unit: "%",
                      baseColor: state.vehicleType == VehicleType.ev ? Colors.green : Colors.orange,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: CustomPaint(
                    painter: GaugePainter(
                      value: state.speed.toDouble(),
                      maxVal: 140,
                      label: state.text('speed'),
                      unit: "KM/H",
                      baseColor: Colors.blueAccent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Digital EV/ICE metrics
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(state.vehicleType == VehicleType.ev ? state.text('power_flow') : state.text('fuel_flow'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(height: 4),
                  Text(
                    state.vehicleType == VehicleType.ev
                        ? "${state.powerUsage >= 0 ? '+' : ''}${state.powerUsage.toStringAsFixed(1)} kW"
                        : "${state.fuelFlowRate.toStringAsFixed(1)} L/h",
                    style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: state.vehicleType == VehicleType.ev
                          ? (state.powerUsage < 0 ? Colors.green : Colors.blueAccent)
                          : Colors.orange,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(state.text('motor_speed'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(height: 4),
                  Text(
                    "${state.rpm} RPM",
                    style: const TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.black87,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Linear bars
          if (state.vehicleType == VehicleType.ev) ...[
            _buildProgressMetric(
              state.text('power_usage_flow'),
              "${state.powerUsage >= 0 ? '+' : ''}${state.powerUsage.toStringAsFixed(1)} kW",
              ((state.powerUsage + 50.0) / 200.0).clamp(0.0, 1.0),
              state.powerUsage < 0 ? Colors.green : Colors.blueAccent,
            ),
            const SizedBox(height: 16),
            _buildProgressMetric(
              state.text('battery_temp'),
              "${state.batteryTemp.round()}°C",
              (state.batteryTemp / 85.0).clamp(0.0, 1.0),
              Colors.orange,
            ),
          ] else ...[
            _buildProgressMetric(
              state.text('engine_load'),
              "${state.engineLoad.round()}%",
              state.engineLoad / 100.0,
              Colors.orange,
            ),
            const SizedBox(height: 16),
            _buildProgressMetric(
              state.text('coolant_temp_ice'),
              "${state.coolantTemp.round()}°C",
              (state.coolantTemp / 120.0).clamp(0.0, 1.0),
              Colors.redAccent,
            ),
          ],
          const SizedBox(height: 16),
          _buildProgressMetric(
            state.text('accelerator'),
            "${state.throttle}%",
            state.throttle / 100.0,
            Colors.blueAccent,
          ),
          const SizedBox(height: 20),
          Text(state.vehicleType == VehicleType.ev ? state.text('live_energy_flow') : state.text('live_fuel_flow'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
          const SizedBox(height: 6),
          _buildPowerChart(state),
          const SizedBox(height: 24),
          // Live Command Console
          Container(
            height: 200,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.black.withOpacity(0.05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(state.text('logs'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
                    Icon(Icons.terminal, size: 12, color: Colors.grey[600]),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: state.consoleLogs.length,
                    itemBuilder: (context, index) {
                      final log = state.consoleLogs[index];
                      final isRx = log.contains("◀");
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4.0),
                        child: Text(
                          log,
                          style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontSize: 10,
                            color: isRx ? Colors.green[700] : Colors.blue[700],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildProgressMetric(String title, String valueText, double percent, Color fillCol) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black54)),
            Text(valueText, style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent,
            minHeight: 8,
            backgroundColor: Colors.black.withOpacity(0.06),
            color: fillCol,
          ),
        ),
      ],
    );
  }

  Widget _buildMapPanel(OBDState state) {
    final List<Map<String, dynamic>> mockChargingStations = [];
    final List<Map<String, dynamic>> mockGasStations = [];

    final destText = _destController.text.toLowerCase();

    if (destText.contains("ตาก") || destText.contains("tak") || destText.contains("เขาหลวง") || destText.contains("khao luang")) {
      mockChargingStations.addAll([
        {
          "name": "PTT EV Station Kamphaeng Phet",
          "location": const LatLng(16.4800, 99.5200),
          "power": "120 kW CCS2",
          "status": "Available"
        },
        {
          "name": "EA Anywhere Tak",
          "location": const LatLng(16.8800, 99.1200),
          "power": "100 kW CCS2",
          "status": "Available"
        },
        {
          "name": "PEA VOLTA Sing Buri Bypass",
          "location": const LatLng(14.8900, 100.4000),
          "power": "120 kW CCS2",
          "status": "Available"
        }
      ]);
      mockGasStations.addAll([
        {
          "name": "PTT Station Kamphaeng Phet",
          "location": const LatLng(16.4820, 99.5220),
          "power": "Gasohol 95 / Diesel",
          "status": "Available"
        },
        {
          "name": "PTT Station Tak Bypass",
          "location": const LatLng(16.8820, 99.1220),
          "power": "Gasohol 95 / E20 / Diesel",
          "status": "Available"
        }
      ]);
    } else if (destText.contains("เชียงใหม่") || destText.contains("chiang") || destText.contains("lampang") || destText.contains("ลำปาง")) {
      mockChargingStations.addAll([
        {
          "name": "PTT EV Station Nakhon Sawan",
          "location": const LatLng(15.7000, 100.1200),
          "power": "150 kW CCS2",
          "status": "Available"
        },
        {
          "name": "PEA VOLTA Lampang",
          "location": const LatLng(18.2900, 99.4900),
          "power": "120 kW CCS2",
          "status": "Available"
        },
        {
          "name": "PEA VOLTA Sing Buri Bypass",
          "location": const LatLng(14.8900, 100.4000),
          "power": "120 kW CCS2",
          "status": "Available"
        }
      ]);
      mockGasStations.addAll([
        {
          "name": "PTT Station Nakhon Sawan",
          "location": const LatLng(15.7020, 100.1220),
          "power": "Gasohol 95 / E20 / Diesel",
          "status": "Available"
        },
        {
          "name": "Shell Lampang",
          "location": const LatLng(18.2920, 99.4920),
          "power": "V-Power 95 / Diesel",
          "status": "Available"
        }
      ]);
    } else {
      mockChargingStations.addAll([
        {
          "name": "PEA VOLTA Bangpakong Charger",
          "location": const LatLng(13.5620, 100.9500),
          "power": "120 kW CCS2",
          "status": "Available"
        },
        {
          "name": "PTT EV Station Chonburi Supercharge",
          "location": const LatLng(13.3600, 100.9900),
          "power": "150 kW CCS2",
          "status": "Available"
        },
        {
          "name": "PEA VOLTA Sri Racha Bypass",
          "location": const LatLng(13.1600, 100.9300),
          "power": "120 kW CCS2",
          "status": "Available"
        },
        {
          "name": "EA Anywhere Pattaya North",
          "location": const LatLng(12.9450, 100.8950),
          "power": "100 kW CCS2",
          "status": "Available"
        }
      ]);
      mockGasStations.addAll([
        {
          "name": "PTT Station Bangpakong",
          "location": const LatLng(13.5640, 100.9520),
          "power": "Gasohol 95 / E20 / Diesel",
          "status": "Available"
        },
        {
          "name": "Shell Chonburi Bypass",
          "location": const LatLng(13.3620, 100.9920),
          "power": "V-Power 95 / Diesel",
          "status": "Available"
        },
        {
          "name": "Bangchak Sri Racha",
          "location": const LatLng(13.1620, 100.9320),
          "power": "E85 / E20 / Gasohol 95",
          "status": "Available"
        },
        {
          "name": "PTT Station Pattaya Central",
          "location": const LatLng(12.9470, 100.8970),
          "power": "Gasohol 95 / Diesel",
          "status": "Available"
        }
      ]);
    }

    final stations = state.vehicleType == VehicleType.ev ? mockChargingStations : mockGasStations;
    final themeColor = state.vehicleType == VehicleType.ev ? Colors.green : Colors.orange;
    final stationIcon = state.vehicleType == VehicleType.ev ? Icons.ev_station : Icons.local_gas_station;

    // Generate vehicle coordinate point marker list
    List<Marker> markers = [];
    if (state.routePoints.isNotEmpty) {
      markers.add(
        Marker(
          point: state.routePoints.first,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: state.vehicleType == VehicleType.ev ? Colors.green : Colors.orange,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      );
      markers.add(
        Marker(
          point: state.routePoints.last,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: Colors.redAccent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      );
    }
    if (state.vehiclePosition != null) {
      markers.add(
        Marker(
          point: state.vehiclePosition!,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: Colors.blueAccent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [BoxShadow(color: Colors.blueAccent.withOpacity(0.5), blurRadius: 12, spreadRadius: 2)],
            ),
          ),
        ),
      );
    }

    // Add station markers with popup details sheet
    for (var station in stations) {
      markers.add(
        Marker(
          point: station['location'],
          width: 32,
          height: 32,
          child: GestureDetector(
            onTap: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                builder: (context) {
                  return Container(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(station['name'], style: TextStyle(fontFamily: 'Space Grotesk', fontSize: 15, fontWeight: FontWeight.bold, color: themeColor)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: themeColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                station['status'] == 'Available' && state.language == 'th' ? 'พร้อมใช้งาน' : station['status'],
                                style: TextStyle(fontSize: 10, color: themeColor, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          state.vehicleType == VehicleType.ev 
                              ? (state.language == 'th' ? "ประเภทหัวชาร์จ: ${station['power']}" : "Connector Type: ${station['power']}")
                              : (state.language == 'th' ? "ประเภทน้ำมัน: ${station['power']}" : "Fuel Types: ${station['power']}"),
                          style: const TextStyle(color: Colors.black87, fontSize: 12),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.black87,
                                  side: const BorderSide(color: Colors.black12),
                                ),
                                icon: const Icon(Icons.navigation, size: 16),
                                label: Text(state.text('route_here')),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _destController.text = station['name'];
                                  _mapService.calculateRoute(
                                    {"latitude": 13.7563, "longitude": 100.5018}, // Bangkok
                                    {"latitude": station['location'].latitude, "longitude": station['location'].longitude}
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: themeColor,
                                  foregroundColor: Colors.white,
                                ),
                                icon: Icon(state.vehicleType == VehicleType.ev ? Icons.flash_on : Icons.local_gas_station, size: 16),
                                label: Text(state.vehicleType == VehicleType.ev ? state.text('plug_charge') : state.text('start_refueling')),
                                onPressed: () {
                                  Navigator.pop(context);
                                  state.setCharging(true);
                                  if (state.isSimulatorMode == false) {
                                    state.setConnectionMode(simulator: true);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
            child: Container(
              decoration: BoxDecoration(
                color: themeColor.withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(color: themeColor, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: themeColor.withOpacity(0.3),
                    blurRadius: 6,
                    spreadRadius: 1,
                  )
                ],
              ),
              child: Icon(stationIcon, color: themeColor, size: 16),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        // Flutter Map widget
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: const LatLng(13.7563, 100.5018),
            initialZoom: 11.0,
            onMapReady: () {
              state.addLog("Map system mounted.");
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              retinaMode: RetinaMode.isHighDensity(context),
            ),
            if (state.routePoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: state.routePoints,
                    strokeWidth: 5,
                    color: Colors.blueAccent.withOpacity(0.8),
                    borderColor: Colors.blueAccent.withOpacity(0.2),
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
            MarkerLayer(markers: markers),
          ],
        ),
        
        // Navigation Form Card
        Positioned(
          top: 16,
          left: 16,
          child: Container(
            width: 300,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black.withOpacity(0.08)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20)],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.route, color: Colors.blueAccent, size: 16),
                        const SizedBox(width: 6),
                        Text(state.text('route_planner'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: Colors.black87)),
                      ],
                    ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _showVoiceAssistantDialog(state),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.mic, color: Colors.blueAccent, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildSearchTextField(state.text('start_point'), _startController, state),
                const SizedBox(height: 8),
                _buildSearchTextField(state.text('destination'), _destController, state),
                const SizedBox(height: 12),
                
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 38),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: _isLoadingRoute ? null : () => _onCalculateRoute(state),
                  icon: _isLoadingRoute 
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.map, size: 16),
                  label: Text(state.text('get_directions'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ),
                
                // Route simulation controls
                if (state.routePoints.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(color: Colors.black12),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(state.text('distance'), style: const TextStyle(fontSize: 9, color: Colors.black54)),
                          Text(
                            "${(state.totalDistance / 1000).toStringAsFixed(1)} km",
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueAccent),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(state.text('est_duration'), style: const TextStyle(fontSize: 9, color: Colors.black54)),
                          Text(
                            "${(state.totalDuration / 3600).toStringAsFixed(1)} hrs",
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blueAccent),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (state.isSimulatorMode) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueAccent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            ),
                            onPressed: () {
                              if (state.isDriving) {
                                _mapService.stopDriving();
                              } else {
                                _mapService.startDriving(_simulator);
                              }
                            },
                            icon: Icon(state.isDriving ? Icons.pause : Icons.play_arrow),
                            label: Text(state.isDriving ? state.text('pause') : state.text('drive'), style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withOpacity(0.04),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: const BorderSide(color: Colors.black12)),
                          ),
                          onPressed: () {
                            _mapService.stopDriving();
                            state.resetTrip();
                            _mapController.move(state.routePoints.first, 12);
                          },
                          icon: const Icon(Icons.refresh, color: Colors.black87),
                        )
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Simulation speed multiplier buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [1, 5, 15, 40].map((speed) {
                        final isActive = state.simulationSpeed == speed;
                        return Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 2.0),
                            height: 24,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.zero,
                                backgroundColor: isActive ? Colors.blueAccent : Colors.transparent,
                                foregroundColor: isActive ? Colors.white : Colors.black87,
                                side: BorderSide(color: isActive ? Colors.blueAccent : Colors.black12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              ),
                              onPressed: () {
                                state.setSimulationSpeed(speed);
                                _simulator.setSpeedMultiplier(speed);
                              },
                              child: Text("${speed}x", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ]
              ],
            ),
          ),
        )
      ],
    );
  }

  Widget _buildSearchTextField(String label, TextEditingController controller, OBDState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.black54)),
        const SizedBox(height: 4),
        SizedBox(
          height: 32,
          child: TextField(
            controller: controller,
            style: const TextStyle(fontSize: 12, color: Colors.black87),
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              filled: true,
              fillColor: Colors.black.withOpacity(0.04),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.black12)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Colors.blueAccent)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDiagnosticsPanel(OBDState state) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(state.text('diagnostics'), style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, letterSpacing: 1.0, color: Colors.black87)),
          const SizedBox(height: 16),
          _buildCellVoltagesGrid(state),
          const SizedBox(height: 20),
          // DTC Status Container
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: state.activeDtcList.isEmpty ? Colors.green.withOpacity(0.05) : Colors.red.withOpacity(0.05),
              border: Border.all(color: state.activeDtcList.isEmpty ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      state.activeDtcList.isEmpty ? Icons.check_circle : Icons.warning,
                      color: state.activeDtcList.isEmpty ? Colors.green : Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      state.activeDtcList.isEmpty ? state.text('healthy') : state.text('unhealthy'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: state.activeDtcList.isEmpty ? Colors.green : Colors.redAccent,
                      ),
                    ),
                  ],
                ),
                Text(
                  state.activeDtcList.isEmpty ? state.text('no_faults') : "${state.activeDtcList.length} ${state.text('faults')}",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: state.activeDtcList.isEmpty ? Colors.green : Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),
          if (state.activeDtcList.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 100,
              child: ListView.builder(
                itemCount: state.activeDtcList.length,
                itemBuilder: (context, index) {
                  final dtc = state.activeDtcList[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.02),
                      border: Border.all(color: Colors.black.withOpacity(0.04)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(dtc['code']!, style: const TextStyle(fontFamily: 'Space Grotesk', color: Colors.redAccent, fontWeight: FontWeight.bold)),
                        Text(
                          state.language == 'th' && dtc['code'] == 'P0A80' ? 'แรงดันเซลล์แบตเตอรี่ไม่สมดุล / เสื่อมสภาพ' :
                          state.language == 'th' && dtc['code'] == 'P0A1B' ? 'การทำงานของอินเวอร์เตอร์มอเตอร์ขับเคลื่อนขัดข้อง' :
                          state.language == 'th' && dtc['code'] == 'P0C73' ? 'ระบบควบคุมปั๊มน้ำหล่อเย็นมอเตอร์ทำงานผิดพลาด' :
                          state.language == 'th' && dtc['code'] == 'P0302' ? 'ตรวจพบลูกสูบที่ 2 จุดระเบิดขัดข้อง (Misfire)' :
                          state.language == 'th' && dtc['code'] == 'P0171' ? 'ส่วนผสมน้ำมันเชื้อเพลิงบางเกินไป (Lean)' :
                          state.language == 'th' && dtc['code'] == 'P0420' ? 'ประสิทธิภาพแคทาไลติกคอนเวอร์เตอร์ต่ำกว่าเกณฑ์' :
                          dtc['desc']!,
                          style: const TextStyle(color: Colors.black54, fontSize: 11),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.black87,
                    side: const BorderSide(color: Colors.black12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => state.clearDtcs(),
                  child: Text(state.text('clear_dtcs'), style: const TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.withOpacity(0.2),
                    foregroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () {
                    if (state.vehicleType == VehicleType.ev) {
                      final errors = [
                        {"code": "P0A80", "desc": "EV Battery Pack Cell Mismatch / Degradation"},
                        {"code": "P0A1B", "desc": "Drive Motor Inverter Performance Fault"},
                        {"code": "P0C73", "desc": "Motor Coolant Pump Control Circuit Failure"},
                      ];
                      final random = errors[DateTime.now().second % errors.length];
                      state.injectDtc(random['code']!, random['desc']!);
                    } else {
                      final errors = [
                        {"code": "P0302", "desc": "Cylinder 2 Misfire Detected"},
                        {"code": "P0171", "desc": "System Too Lean (Bank 1)"},
                        {"code": "P0420", "desc": "Catalyst System Efficiency Below Threshold"},
                      ];
                      final random = errors[DateTime.now().second % errors.length];
                      state.injectDtc(random['code']!, random['desc']!);
                    }
                  },
                  child: Text(state.text('inject_error'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              )
            ],
          ),
          const SizedBox(height: 24),
          Text(state.text('smart_logs'), style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, letterSpacing: 1.0, color: Colors.black87)),
          const SizedBox(height: 12),
          // Alerts List
          SizedBox(
            height: 250,
            child: ListView.builder(
              itemCount: state.alertList.length,
              itemBuilder: (context, index) {
                final alert = state.alertList[index];
                Color borderCol = Colors.blueAccent;
                IconData alertIcon = Icons.info;
                if (alert['type'] == 'warning') {
                  borderCol = Colors.orange;
                  alertIcon = Icons.warning;
                } else if (alert['type'] == 'danger') {
                  borderCol = Colors.redAccent;
                  alertIcon = Icons.error;
                }
                
                // Dynamic translation of alert messages
                String translatedTitle = alert['title'];
                String translatedMessage = alert['message'];
                if (state.language == 'th') {
                  if (alert['title'] == 'EV Ready') {
                    translatedTitle = 'รถ EV พร้อมใช้งาน';
                    translatedMessage = 'วางแผนเส้นทางหรือเชื่อมต่อ OBD2 เพื่อเริ่มติดตามข้อมูลสถานะรถ';
                  } else if (alert['title'] == 'Charging Initiated') {
                    if (state.vehicleType == VehicleType.ev) {
                      translatedTitle = 'เริ่มเสียบชาร์จแล้ว';
                      translatedMessage = 'เชื่อมต่อตู้ชาร์จไฟด่วน CCS2 120kW เรียบร้อย';
                    } else {
                      translatedTitle = 'เริ่มเติมน้ำมันแล้ว';
                      translatedMessage = 'เชื่อมต่อหัวจ่ายน้ำมันเชื้อเพลิงสำเร็จ';
                    }
                  } else if (alert['title'] == 'Charging Stopped') {
                    if (state.vehicleType == VehicleType.ev) {
                      translatedTitle = 'หยุดชาร์จไฟแล้ว';
                      translatedMessage = 'ถอดขั้วชาร์จตู้ CCS2 ออกแล้ว';
                    } else {
                      translatedTitle = 'เติมน้ำมันเสร็จสิ้น';
                      translatedMessage = 'ถอดหัวจ่ายน้ำมันเชื้อเพลิงออกแล้ว';
                    }
                  } else if (alert['title'] == 'Route Planned') {
                    translatedTitle = 'วางแผนเส้นทางแล้ว';
                    translatedMessage = 'ค้นหาและสร้างแผนที่นำทางเรียบร้อย';
                  } else if (alert['title'] == 'Engine Active') {
                    translatedTitle = 'ระบบขับเคลื่อนพร้อม';
                    translatedMessage = 'เริ่มจำลองการเคลื่อนที่ของรถยนต์';
                  } else if (alert['title'] == 'Engine Idle') {
                    translatedTitle = 'จอดนิ่งสนิท';
                    translatedMessage = 'หยุดการจำลองการขับเคลื่อนชั่วคราว';
                  } else if (alert['title'] == 'Simulation Reset') {
                    translatedTitle = 'รีเซ็ตข้อมูลจำลอง';
                    translatedMessage = state.vehicleType == VehicleType.ev
                        ? 'รถยนต์กลับไปจุดเริ่มต้นพร้อมชาร์จแบตเตอรี่เต็ม 100%'
                        : 'รถยนต์กลับไปจุดเริ่มต้นพร้อมเติมน้ำมันเต็มถัง 100%';
                  } else if (alert['title'] == 'DTC Active: P0A80') {
                    translatedTitle = 'ตรวจพบรหัสขัดข้อง: P0A80';
                    translatedMessage = 'แบตเตอรี่แรงดันไม่สมดุล ควรนำรถเข้าตรวจเช็คทันที';
                  } else if (alert['title'] == 'DTC Active: P0A1B') {
                    translatedTitle = 'ตรวจพบรหัสขัดข้อง: P0A1B';
                    translatedMessage = 'อินเวอร์เตอร์ระบบขับเคลื่อนทำงานผิดปกติ';
                  } else if (alert['title'] == 'DTC Active: P0C73') {
                    translatedTitle = 'ตรวจพบรหัสขัดข้อง: P0C73';
                    translatedMessage = 'ปั๊มน้ำหล่อเย็นมอเตอร์ทำงานล้มเหลว';
                  } else if (alert['title'] == 'DTC Active: P0302') {
                    translatedTitle = 'พบรหัสขัดข้อง: P0302';
                    translatedMessage = 'ลูกสูบที่ 2 จุดระเบิดขัดข้อง (Misfire) โปรดเช็คคอยล์หัวเทียน';
                  } else if (alert['title'] == 'DTC Active: P0171') {
                    translatedTitle = 'พบรหัสขัดข้อง: P0171';
                    translatedMessage = 'ส่วนผสมอากาศ/น้ำมันบางเกินไป (System Lean)';
                  } else if (alert['title'] == 'DTC Active: P0420') {
                    translatedTitle = 'พบรหัสขัดข้อง: P0420';
                    translatedMessage = 'ประสิทธิภาพแคทาไลเซอร์ต่ำกว่าเกณฑ์การบำบัดไอเสีย';
                  } else if (alert['title'] == 'DTC Cleared') {
                    translatedTitle = 'ล้างรหัสโค้ดขัดข้อง';
                    translatedMessage = 'เคลียร์รหัสปัญหาเรียบร้อย ปิดไฟแจ้งเตือนที่หน้าจอ';
                  } else if (alert['title'] == 'Low Battery Warning') {
                    translatedTitle = 'เตือนแบตเตอรี่ต่ำ';
                    translatedMessage = 'ระดับแบตเตอรี่ต่ำกว่า 15% กรุณาชาร์จไฟด่วน';
                  } else if (alert['title'] == 'Low Fuel Warning') {
                    translatedTitle = 'เตือนน้ำมันใกล้หมด';
                    translatedMessage = 'ระดับน้ำมันเชื้อเพลิงต่ำกว่า 15% กรุณาเติมน้ำมันด่วน';
                  } else if (alert['title'].contains('Battery Overheating')) {
                    translatedTitle = 'แบตเตอรี่ร้อนเกินไป';
                    translatedMessage = 'อุณหภูมิของแบตเตอรี่ร้อนเกินกำหนด จำกัดกำลังไฟฟ้าลง';
                  } else if (alert['title'].contains('Engine Overheating')) {
                    translatedTitle = 'เครื่องยนต์ร้อนเกินไป';
                    translatedMessage = 'อุณหภูมิน้ำหล่อเย็นสูงเกินขีดจำกัด โปรดเช็คหม้อน้ำ';
                  } else if (alert['title'] == 'Speed Advisory') {
                    translatedTitle = 'เตือนจำกัดความเร็ว';
                    translatedMessage = 'ความเร็วรถเกิน 110 กม./ชม. โปรดใช้ความระมัดระวัง';
                  } else if (alert['title'] == 'OBD2 Paired') {
                    translatedTitle = 'เชื่อมต่อ OBD2 สำเร็จ';
                    translatedMessage = 'สามารถจับคู่เชื่อมต่อข้อมูลกับอุปกรณ์สำเร็จ';
                  }
                }

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.01),
                    border: Border(left: BorderSide(color: borderCol, width: 3)),
                    borderRadius: const BorderRadius.only(topRight: Radius.circular(6), bottomRight: Radius.circular(6)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(alertIcon, color: borderCol, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(translatedTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.black87)),
                            const SizedBox(height: 2),
                            Text(translatedMessage, style: const TextStyle(color: Colors.black54, fontSize: 11)),
                          ],
                        ),
                      ),
                      Text(alert['time'], style: const TextStyle(color: Colors.black38, fontSize: 9)),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          // Current direction instruction
          Container(
            height: 80,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.02),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.black.withOpacity(0.04)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state.text('instruction'), style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.black54)),
                const SizedBox(height: 4),
                Expanded(
                  child: Text(
                    state.routeSteps.isNotEmpty && state.currentCoordIndex < state.routeSteps.length
                      ? (() {
                          // Clean up steps instruction
                          String orig = state.routeSteps.firstWhere(
                            (step) => const Distance().as(LengthUnit.Meter, state.vehiclePosition!, step['location']) < 300,
                            orElse: () => state.routeSteps.first,
                          )['instruction'];
                          if (state.language == 'th') {
                            // Translate common navigation words
                            if (orig.contains("Head north")) return "มุ่งหน้าไปทางทิศเหนือ";
                            if (orig.contains("Head south")) return "มุ่งหน้าไปทางทิศใต้";
                            if (orig.contains("Turn left")) return "เลี้ยวซ้าย";
                            if (orig.contains("Turn right")) return "เลี้ยวขวา";
                            if (orig.contains("Keep left")) return "ชิดซ้าย";
                            if (orig.contains("Keep right")) return "ชิดขวา";
                            if (orig.contains("Merge onto")) return "เบี่ยงเข้าสู่";
                            if (orig.contains("Take the ramp")) return "ใช้ทางลาด";
                            if (orig.contains("At the roundabout")) return "ที่วงเวียน";
                            if (orig.contains("destination")) return "ถึงจุดหมายปลายทางแล้ว";
                          }
                          return orig;
                        })()
                      : state.text('waiting_nav'),
                    style: const TextStyle(fontSize: 11, color: Colors.black87),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPowerChart(OBDState state) {
    final history = state.vehicleType == VehicleType.ev ? state.powerHistory : state.fuelFlowHistory;
    if (history.isEmpty) {
      return SizedBox(
        height: 120,
        child: Center(
          child: Text(
            state.vehicleType == VehicleType.ev ? state.text('waiting_telemetry') : state.text('waiting_telemetry_ice'),
            style: const TextStyle(color: Colors.black54, fontSize: 11),
          ),
        ),
      );
    }

    final spots = <FlSpot>[];
    for (int i = 0; i < history.length; i++) {
      spots.add(FlSpot(i.toDouble(), history[i]));
    }

    final minY = state.vehicleType == VehicleType.ev ? -60.0 : 0.0;
    final maxY = state.vehicleType == VehicleType.ev ? 160.0 : 25.0;
    final activeColor = state.vehicleType == VehicleType.ev ? Colors.green : Colors.orange;

    return Container(
      height: 120,
      padding: const EdgeInsets.only(top: 10, right: 10),
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: false),
          minY: minY,
          maxY: maxY,
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: activeColor,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: activeColor.withOpacity(0.1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChargingPanel(OBDState state) {
    if (state.vehicleType == VehicleType.ev) {
      final double power = state.powerUsage.abs();
      final double voltage = state.voltage;
      final double current = power * 1000.0 / (voltage > 0 ? voltage : 380.0);
      final double energyAdded = (state.batteryLevel - 10.0).clamp(0.0, 100.0) * 0.6;
      final double cost = energyAdded * 6.5;

      return Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.05),
          border: Border.all(color: Colors.green.withOpacity(0.2)),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.green.withOpacity(0.03),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.green),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      state.text('dc_charging'),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.flash_off, color: Colors.redAccent, size: 18),
                  onPressed: () => state.setCharging(false),
                  tooltip: "Stop Charging",
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(state.text('charging_speed'), style: const TextStyle(fontSize: 9, color: Colors.black54)),
                    const SizedBox(height: 4),
                    Text("${power.toStringAsFixed(1)} kW", style: const TextStyle(fontFamily: 'Space Grotesk', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(state.text('voltage_current'), style: const TextStyle(fontSize: 9, color: Colors.black54)),
                    const SizedBox(height: 4),
                    Text("${voltage.toStringAsFixed(1)}V @ ${current.round()}A", style: const TextStyle(fontFamily: 'Space Grotesk', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                  ],
                ),
              ],
            ),
            const Divider(height: 16, color: Colors.black12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildChargingStat(state.text('added_energy'), "${energyAdded.toStringAsFixed(1)} kWh"),
                _buildChargingStat(state.text('added_range'), "+${(energyAdded * 6.5).round()} km"),
                _buildChargingStat(state.text('est_cost'), "${cost.toStringAsFixed(2)} ฿"),
              ],
            ),
          ],
        ),
      );
    } else {
      // ICE Refueling Panel
      final double fuelAdded = (state.fuelLevel - 10.0).clamp(0.0, 100.0) * 0.5;
      final double cost = fuelAdded * 38.5;
      final double addedRange = fuelAdded * 14.2;

      return Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.05),
          border: Border.all(color: Colors.orange.withOpacity(0.2)),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.orange.withOpacity(0.03),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      state.text('refueling_active'),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.local_gas_station_outlined, color: Colors.redAccent, size: 18),
                  onPressed: () => state.setCharging(false),
                  tooltip: "Stop Fueling",
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(state.text('refuel_speed'), style: const TextStyle(fontSize: 9, color: Colors.black54)),
                    const SizedBox(height: 4),
                    const Text("35 L/min", style: TextStyle(fontFamily: 'Space Grotesk', fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange)),
                  ],
                ),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text("FUELING STATUS", style: TextStyle(fontSize: 9, color: Colors.black54)),
                    SizedBox(height: 4),
                    Text("Accessory Mode", style: TextStyle(fontFamily: 'Space Grotesk', fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                  ],
                ),
              ],
            ),
            const Divider(height: 16, color: Colors.black12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildChargingStat(state.text('added_fuel'), "${fuelAdded.toStringAsFixed(1)} L"),
                _buildChargingStat(state.text('added_fuel_range'), "+${addedRange.round()} km"),
                _buildChargingStat(state.text('est_fuel_cost'), "${cost.toStringAsFixed(2)} ฿"),
              ],
            ),
          ],
        ),
      );
    }
  }

  Widget _buildChargingStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 8, color: Colors.black54)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontFamily: 'Space Grotesk', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87)),
      ],
    );
  }

  Widget _buildCellVoltagesGrid(OBDState state) {
    if (state.vehicleType == VehicleType.ev) {
      final hasCellFailure = state.activeDtcList.any((dtc) => dtc['code'] == 'P0A80');
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.02),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(state.text('cell_balance'), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black54)),
                Text(
                  hasCellFailure ? state.text('unbalanced') : state.text('balanced'),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: hasCellFailure ? Colors.redAccent : Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 96,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 24,
                crossAxisSpacing: 2,
                mainAxisSpacing: 3,
                childAspectRatio: 0.6,
              ),
              itemBuilder: (context, index) {
                final volt = state.cellVoltages[index];
                Color barColor = Colors.green;
                if (volt < 3.5) {
                  barColor = Colors.redAccent;
                } else if (volt < 4.0) {
                  barColor = Colors.orange;
                }
                return Container(
                  decoration: BoxDecoration(
                    color: barColor.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(1),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Cell 1 - 24", style: TextStyle(fontSize: 8, color: Colors.black38)),
                if (hasCellFailure)
                  Text(state.text('cell_fault'), style: const TextStyle(fontSize: 8, color: Colors.redAccent, fontWeight: FontWeight.bold))
                else
                  Text(state.text('voltage_delta'), style: const TextStyle(fontSize: 8, color: Colors.black38)),
                const Text("Cell 73 - 96", style: TextStyle(fontSize: 8, color: Colors.black38)),
              ],
            )
          ],
        ),
      );
    } else {
      // ICE Cylinder Trim balance panel
      final hasMisfire = state.activeDtcList.any((dtc) => dtc['code'] == 'P0302');
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.02),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(state.text('cylinder_trim'), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black54)),
                Text(
                  hasMisfire ? state.text('unbalanced_ice') : state.text('balanced_ice'),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: hasMisfire ? Colors.redAccent : Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Render 4 Cylinder Trim progress bars
            Column(
              children: List.generate(4, (index) {
                final double trim = state.cylinderFuelTrims[index];
                Color trimColor = Colors.green;
                if (trim.abs() > 10.0) {
                  trimColor = Colors.redAccent;
                } else if (trim.abs() > 5.0) {
                  trimColor = Colors.orange;
                }
                // Map trim value from -15% to +15% to 0.0 to 1.0 progress indicator
                final double pct = ((trim + 15.0) / 30.0).clamp(0.0, 1.0);
                
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 60,
                        child: Text("Cyl ${index + 1}", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black87)),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 6,
                            backgroundColor: Colors.black.withOpacity(0.06),
                            color: trimColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 45,
                        child: Text(
                          "${trim >= 0 ? '+' : ''}${trim.toStringAsFixed(1)}%",
                          textAlign: TextAlign.end,
                          style: TextStyle(fontSize: 10, fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, color: trimColor),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            const Divider(height: 12, color: Colors.black12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("${state.text('spark_adv')}:", style: const TextStyle(fontSize: 10, color: Colors.black54)),
                Text(
                  "${state.sparkAdvance.toStringAsFixed(1)}° BTDC",
                  style: const TextStyle(fontSize: 10, fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, color: Colors.blueAccent),
                ),
              ],
            )
          ],
        ),
      );
    }
  }

  Widget _buildEcoComparisonCard(OBDState state) {
    final hasRoute = state.routePoints.isNotEmpty;
    // Default 100 km demo if no route is planned yet
    final double distance = hasRoute ? state.totalDistance : 100000.0;
    
    final evCost = state.getEstimatedTripCost(VehicleType.ev, distance);
    final iceCost = state.getEstimatedTripCost(VehicleType.ice, distance);
    
    final evCO2 = state.getEstimatedTripCO2(VehicleType.ev, distance);
    final iceCO2 = state.getEstimatedTripCO2(VehicleType.ice, distance);
    
    final costSavings = iceCost - evCost;
    final co2Savings = iceCO2 - evCO2;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [Colors.white, Colors.grey[50]!],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.eco, color: Colors.green, size: 20),
                    const SizedBox(width: 6),
                    Text(
                      state.text('eco_comparison'),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5),
                    ),
                  ],
                ),
                if (!hasRoute)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      state.language == 'th' ? "จำลอง 100 กม." : "Demo 100 km",
                      style: const TextStyle(fontSize: 9, color: Colors.blueAccent, fontWeight: FontWeight.bold),
                    ),
                  )
                else
                  Text(
                    "${(distance / 1000).toStringAsFixed(1)} km",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.blueAccent),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                // EV Panel
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withOpacity(0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.electric_car, color: Colors.green, size: 16),
                            const SizedBox(width: 4),
                            Text(
                              state.language == 'th' ? "ไฟฟ้า (EV)" : "Electric (EV)",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.green),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          state.text('electricity_cost'),
                          style: const TextStyle(fontSize: 8, color: Colors.black54),
                        ),
                        Text(
                          "฿${evCost.toStringAsFixed(0)}",
                          style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, fontSize: 18, color: Colors.green),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          state.text('co2_emissions'),
                          style: const TextStyle(fontSize: 8, color: Colors.black54),
                        ),
                        Text(
                          "${evCO2.toStringAsFixed(1)} kg",
                          style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // ICE Panel
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.local_gas_station, color: Colors.orange, size: 16),
                            const SizedBox(width: 4),
                            Text(
                              state.language == 'th' ? "น้ำมัน (ICE)" : "Gasoline (ICE)",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.orange),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          state.text('fuel_cost'),
                          style: const TextStyle(fontSize: 8, color: Colors.black54),
                        ),
                        Text(
                          "฿${iceCost.toStringAsFixed(0)}",
                          style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, fontSize: 18, color: Colors.orange),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          state.text('co2_emissions'),
                          style: const TextStyle(fontSize: 8, color: Colors.black54),
                        ),
                        Text(
                          "${iceCO2.toStringAsFixed(1)} kg",
                          style: const TextStyle(fontFamily: 'Space Grotesk', fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Savings Summary
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.1)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.stars, color: Colors.blueAccent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.text('you_save'),
                          style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          state.language == 'th'
                              ? "ประหยัดเงิน ฿${costSavings.toStringAsFixed(0)} | ลดก๊าซ CO2 ${co2Savings.toStringAsFixed(1)} kg"
                              : "Save ฿${costSavings.toStringAsFixed(0)} | Reduce ${co2Savings.toStringAsFixed(1)} kg CO2",
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.black87),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVehicleProfilePanel(OBDState state) {
    final isEv = state.vehicleType == VehicleType.ev;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                state.text('vehicle_profile'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  fontSize: 14,
                  color: Colors.black87,
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey[600],
                  padding: EdgeInsets.zero,
                ),
                onPressed: () {
                  state.resetProfileToDefaults();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.text('reset_profile')),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(Icons.restore, size: 14),
                label: Text(state.text('reset_profile'), style: const TextStyle(fontSize: 10)),
              )
            ],
          ),
          const SizedBox(height: 12),

          // Powertrain Switcher Row
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.black.withOpacity(0.04)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (!isEv) {
                        state.setVehicleType(VehicleType.ev);
                        if (state.isSimulatorMode) _simulator.start();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: isEv ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: isEv
                            ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))]
                            : [],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.electric_car, size: 16, color: isEv ? Colors.green : Colors.black54),
                          const SizedBox(width: 6),
                          Text(
                            "ELECTRIC (EV)",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isEv ? Colors.green : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      if (isEv) {
                        state.setVehicleType(VehicleType.ice);
                        if (state.isSimulatorMode) _simulator.start();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: !isEv ? Colors.white : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: !isEv
                            ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))]
                            : [],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.local_gas_station, size: 16, color: !isEv ? Colors.orange : Colors.black54),
                          const SizedBox(width: 6),
                          Text(
                            "GASOLINE (ICE)",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: !isEv ? Colors.orange : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          _buildEcoComparisonCard(state),
          const SizedBox(height: 20),

          Text(
            state.text('spec_sheet'),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey[800], letterSpacing: 0.5),
          ),
          const SizedBox(height: 12),

          if (isEv) ...[
            _buildSliderSetting(
              title: state.text('battery_cap'),
              value: state.batteryCapacity,
              min: 20.0,
              max: 120.0,
              unit: "kWh",
              onChanged: (val) => state.setBatteryCapacity(val),
              activeColor: Colors.green,
            ),
            const SizedBox(height: 16),
            _buildSliderSetting(
              title: state.text('ev_efficiency'),
              value: state.evEfficiency,
              min: 100.0,
              max: 250.0,
              unit: "Wh/km",
              onChanged: (val) => state.setEvEfficiency(val),
              activeColor: Colors.green,
            ),
            const SizedBox(height: 16),
            _buildDropdownSetting(
              title: state.text('plug_type'),
              value: state.chargingPlug,
              items: ["CCS2", "Type 2", "GB/T", "CHAdeMO"],
              onChanged: (val) => state.setChargingPlug(val!),
              activeColor: Colors.green,
            ),
          ] else ...[
            _buildSliderSetting(
              title: state.text('tank_size'),
              value: state.fuelTankCapacity,
              min: 30.0,
              max: 100.0,
              unit: "L",
              onChanged: (val) => state.setFuelTankCapacity(val),
              activeColor: Colors.orange,
            ),
            const SizedBox(height: 16),
            _buildSliderSetting(
              title: state.text('fuel_efficiency'),
              value: state.iceEfficiency,
              min: 6.0,
              max: 30.0,
              unit: "km/L",
              onChanged: (val) => state.setIceEfficiency(val),
              activeColor: Colors.orange,
            ),
            const SizedBox(height: 16),
            _buildDropdownSetting(
              title: state.text('fuel_type'),
              value: state.fuelType,
              items: ["Gasohol 95", "E20", "E85", "Diesel"],
              onChanged: (val) => state.setFuelType(val!),
              activeColor: Colors.orange,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSliderSetting({
    required String title,
    required double value,
    required double min,
    required double max,
    required String unit,
    required Function(double) onChanged,
    required Color activeColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black54)),
            Text(
              "${value.toStringAsFixed(1)} $unit",
              style: const TextStyle(fontFamily: 'Space Grotesk', fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: activeColor,
            inactiveTrackColor: activeColor.withOpacity(0.1),
            thumbColor: activeColor,
            overlayColor: activeColor.withOpacity(0.2),
            valueIndicatorColor: activeColor,
            trackHeight: 4,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildDropdownSetting({
    required String title,
    required String value,
    required List<String> items,
    required Function(String?) onChanged,
    required Color activeColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black54)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.black.withOpacity(0.08)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              icon: Icon(Icons.arrow_drop_down, color: activeColor),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
              onChanged: onChanged,
              items: items.map<DropdownMenuItem<String>>((String val) {
                return DropdownMenuItem<String>(
                  value: val,
                  child: Text(val),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

class VoiceAssistantSheet extends StatefulWidget {
  final OBDState state;
  final VoiceAssistantService voiceService;
  final Function(VoiceAssistantResponse response) onStartTrip;

  const VoiceAssistantSheet({
    super.key,
    required this.state,
    required this.voiceService,
    required this.onStartTrip,
  });

  @override
  State<VoiceAssistantSheet> createState() => _VoiceAssistantSheetState();
}

class _VoiceAssistantSheetState extends State<VoiceAssistantSheet> with SingleTickerProviderStateMixin {
  String _speechText = "";
  String _status = "idle"; // idle, listening, thinking, responding
  VoiceAssistantResponse? _response;
  late AnimationController _waveController;
  final TextEditingController _customInputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _waveController.dispose();
    _customInputController.dispose();
    widget.voiceService.stop();
    super.dispose();
  }

  void _triggerVoiceCommand(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _speechText = query;
      _status = "listening";
      _response = null;
    });

    // Simulate listening ripple
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;
    setState(() {
      _status = "thinking";
    });

    // Simulate AI parsing delay
    await Future.delayed(const Duration(milliseconds: 1200));

    if (!mounted) return;
    final res = widget.voiceService.parseCommand(query, widget.state.language);
    setState(() {
      _status = "responding";
      _response = res;
    });

    // Speak it out!
    await widget.voiceService.speak(res.textResponse, widget.state.language);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final isThai = state.language == 'th';

    final List<String> presets = isThai
        ? [
            "ไปเขาหลวง ตาก แบตเหลือ 60%",
            "ไปเชียงใหม่ แบตเหลือ 65%",
            "ไปพัทยา แบตเหลือ 30%",
          ]
        : [
            "Go to Khao Luang Tak with 60% battery",
            "Go to Chiang Mai with 65% battery",
            "Go to Pattaya with 30% battery",
          ];

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        top: 20,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1E222A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 25,
            spreadRadius: 5,
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.mic, color: Colors.blueAccent, size: 24),
                    const SizedBox(width: 8),
                    Text(
                      state.text('voice_copilot'),
                      style: const TextStyle(
                        fontFamily: 'Space Grotesk',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white60),
                  onPressed: () {
                    widget.voiceService.stop();
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              state.text('copilot_speech_desc'),
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 24),

            // Central Wave / Visualizer
            Center(
              child: _buildVisualizer(),
            ),
            const SizedBox(height: 20),

            // Speech Transcript text
            if (_speechText.isNotEmpty) ...[
              Center(
                child: Text(
                  '"$_speechText"',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    fontStyle: FontStyle.italic,
                    color: Colors.blueAccent,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // AI Response UI Card
            if (_status == "responding" && _response != null) _buildResponseCard(isThai),

            // Preset Chips
            if (_status == "idle" || _status == "responding") ...[
              Text(
                state.text('presets'),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: Colors.white60,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: presets.map((preset) {
                  return ActionChip(
                    backgroundColor: Colors.white.withOpacity(0.06),
                    side: BorderSide(color: Colors.white.withOpacity(0.12)),
                    label: Text(
                      preset,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    onPressed: () => _triggerVoiceCommand(preset),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ],

            // Text Input Option
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _customInputController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: state.text('mic_prompt'),
                      hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onSubmitted: (val) {
                      _triggerVoiceCommand(val);
                      _customInputController.clear();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.send, color: Colors.white, size: 18),
                  onPressed: () {
                    _triggerVoiceCommand(_customInputController.text);
                    _customInputController.clear();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVisualizer() {
    if (_status == "idle") {
      return Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: Colors.blueAccent.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.blueAccent.withOpacity(0.3), width: 2),
        ),
        child: const Icon(Icons.mic, color: Colors.blueAccent, size: 36),
      );
    }

    if (_status == "listening") {
      return SizedBox(
        height: 80,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (index) {
            return AnimatedBuilder(
              animation: _waveController,
              builder: (context, child) {
                final double phase = index * (pi / 4);
                final double wave = sin(_waveController.value * 2 * pi + phase);
                final double height = 15 + (wave.abs() * 45);
                return Container(
                  width: 6,
                  height: height,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent,
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blueAccent.withOpacity(0.4),
                        blurRadius: 8,
                      )
                    ],
                  ),
                );
              },
            );
          }),
        ),
      );
    }

    if (_status == "thinking") {
      return SizedBox(
        width: 80,
        height: 80,
        child: AnimatedBuilder(
          animation: _waveController,
          builder: (context, child) {
            return Transform.scale(
              scale: 1.0 + (sin(_waveController.value * 2 * pi).abs() * 0.15),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.purpleAccent.withOpacity(0.4), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.purpleAccent.withOpacity(0.2),
                      blurRadius: 15,
                    )
                  ],
                ),
                child: const Icon(Icons.psychology, color: Colors.purpleAccent, size: 36),
              ),
            );
          },
        ),
      );
    }

    // responding
    return SizedBox(
      height: 80,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(8, (index) {
          return AnimatedBuilder(
            animation: _waveController,
            builder: (context, child) {
              final double phase = index * (pi / 3);
              final double wave = sin(_waveController.value * 3 * pi + phase);
              final double height = 10 + (wave.abs() * 30);
              return Container(
                width: 4,
                height: height,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: Colors.greenAccent,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            },
          );
        }),
      ),
    );
  }

  Widget _buildResponseCard(bool isThai) {
    final res = _response!;
    final state = widget.state;
    final themeColor = state.vehicleType == VehicleType.ev ? Colors.green : Colors.orange;

    return Card(
      color: Colors.white.withOpacity(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withOpacity(0.1)),
      ),
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Voice subtitle text
            Text(
              res.textResponse,
              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            const Divider(color: Colors.white12),
            const SizedBox(height: 8),

            // Summary Stats
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildStatItem(isThai ? "จุดหมาย" : "Destination", res.destination),
                _buildStatItem(isThai ? "ระยะทาง" : "Distance", "${res.distanceKm.round()} km"),
                _buildStatItem(isThai ? "เวลาเดินทาง" : "Duration", "${res.durationHrs.toStringAsFixed(1)} ${isThai ? 'ชม.' : 'hrs'}"),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildStatItem(isThai ? "แบตเริ่ม" : "Start SoC", "${res.initialBattery.round()}%"),
                _buildStatItem(isThai ? "แบตปลายทาง" : "Arrival SoC", "${res.finalBattery.round()}%", color: Colors.greenAccent),
                _buildStatItem(isThai ? "ประมาณการค่าใช้จ่าย" : "Est. Cost", "฿${res.estimatedCost.round()}"),
              ],
            ),

            if (res.recommendedStops.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                state.text('suggested_stops'),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Column(
                children: res.recommendedStops.map((stop) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      children: [
                        Icon(state.vehicleType == VehicleType.ev ? Icons.ev_station : Icons.local_gas_station, size: 14, color: themeColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            stop['name']!,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ),
                        Text(
                          stop['type']!,
                          style: const TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],

            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: themeColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                widget.onStartTrip(res);
                Navigator.pop(context);
              },
              icon: const Icon(Icons.navigation),
              label: Text(
                state.text('start_nav'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(color: Colors.white38, fontSize: 8, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            fontFamily: 'Space Grotesk',
          ),
        ),
      ],
    );
  }
}
