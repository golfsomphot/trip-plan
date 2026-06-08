import 'dart:async';
import 'dart:math';
import '../providers/obd_state.dart';

class OBDSimulator {
  final OBDState state;
  Timer? _timer;
  
  // Physical states
  double _speed = 0.0;
  double _rpm = 800.0; // Motor or Engine RPM
  double _coolantTemp = 30.0; // Battery Pack or Coolant Temp (°C)
  double _fuelLevel = 100.0; // Battery SoC (EV) or Gas Fuel Level (ICE) %
  double _throttle = 0.0; // Accelerator Pedal or Engine Load %
  double _voltage = 396.0; // High-Voltage Traction Battery (EV) or Accessory/12V (ICE)
  double _powerUsage = 0.0; // Power Flow (kW) or Fuel Flow Rate (L/h)

  double _targetSpeed = 0.0;
  bool _isMoving = false;
  int _speedMultiplier = 1;

  OBDSimulator(this.state);

  void start() {
    _timer?.cancel();
    if (state.vehicleType == VehicleType.ice && _coolantTemp < 40) {
      _coolantTemp = 75.0; // Starts relatively warm for ICE to quickly stabilize
    } else if (state.vehicleType == VehicleType.ev && _coolantTemp > 65) {
      _coolantTemp = 30.0; // Cool down for EV
    }
    _fuelLevel = state.fuelLevel;
    state.addLog(state.vehicleType == VehicleType.ev ? "Virtual EV Powertrain initialized." : "Virtual ICE Powertrain initialized.");
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _updatePhysics();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _speed = 0;
    _rpm = state.vehicleType == VehicleType.ev ? 0 : 800;
    _throttle = 0;
    _powerUsage = 0;
    state.addLog(state.vehicleType == VehicleType.ev ? "Virtual EV Powertrain shut down." : "Virtual ICE Powertrain shut down.");
    _pushTelemetry();
  }

  void setTargetSpeed(double target) {
    _targetSpeed = target;
    _isMoving = target > 0;
  }

  void setSpeedMultiplier(int mult) {
    _speedMultiplier = mult;
  }

  void _updatePhysics() {
    if (!state.isSimulatorMode) return;

    if (state.isCharging) {
      _speed = 0.0;
      _rpm = 0.0;
      _throttle = 0.0;
      
      if (state.vehicleType == VehicleType.ev) {
        // Charging rate curve: fast chargers taper speed after 80% to protect battery
        if (_fuelLevel < 80.0) {
          _powerUsage = -120.0; // Max 120 kW charge
        } else if (_fuelLevel < 95.0) {
          // Taper linearly down to -30 kW
          _powerUsage = -120.0 + (_fuelLevel - 80.0) * 6.0;
        } else {
          _powerUsage = -15.0; // Trickle charge
        }

        // Add energy back to battery level (%) based on battery capacity
        final double energyAdded = -_powerUsage * (0.1 / 3600.0) * _speedMultiplier;
        const double scaleFactor = 40.0; // scaled for rapid demonstration charging
        _fuelLevel += (energyAdded / state.batteryCapacity) * 100.0 * scaleFactor;
        if (_fuelLevel >= 100.0) {
          _fuelLevel = 100.0;
          state.setCharging(false); // Auto unplug when full
        }

        // Heat up during DC Fast Charging
        _coolantTemp += (0.04 * _speedMultiplier);
        _coolantTemp = _coolantTemp.clamp(30.0, 52.0);

        // Charger voltage
        _voltage = 385.0 + 15.0 * (_fuelLevel / 100.0) + 2.0;
      } else {
        // ICE Refueling based on tank size
        _powerUsage = 0.0;
        // Refuel rate: 35 Liters/min (0.58 L/sec)
        const double refuelRateLps = 35.0 / 60.0;
        final double fuelAdded = refuelRateLps * 0.1 * _speedMultiplier;
        const double scaleFactor = 15.0; // scaled for visual feedback
        _fuelLevel += (fuelAdded / state.fuelTankCapacity) * 100.0 * scaleFactor;
        if (_fuelLevel >= 100.0) {
          _fuelLevel = 100.0;
          state.setCharging(false); // Auto stop refueling
        }
        _coolantTemp = max(30.0, _coolantTemp - 0.2 * _speedMultiplier); // cools down engine
        _voltage = 12.6; // resting accessory battery voltage
      }

      _pushTelemetry();
      return;
    }

    if (state.vehicleType == VehicleType.ev) {
      // 1. Speeds, Accel & Power Flow physics (EV)
      if (_isMoving) {
        final diff = _targetSpeed - _speed;
        if (diff.abs() > 1.0) {
          if (diff > 0) {
            // Accelerating
            _throttle = min(100.0, _throttle + 5.0);
            _speed += 2.0 * _speedMultiplier;
            // Acceleration draws higher power based on efficiency factor
            _powerUsage = _throttle * (state.evEfficiency / 100.0) * 1.0;
          } else {
            // Decelerating (Regenerative braking)
            _throttle = 0.0;
            _speed -= 3.0 * _speedMultiplier;
            _powerUsage = -35.0; // Regeneration power (charging back)
          }
        } else {
          // Cruising at target speed
          _speed = _targetSpeed;
          _throttle = max(10.0, (_speed / 2.5).roundToDouble());
          // Dynamic cruising power based on EV efficiency
          _powerUsage = _speed * (state.evEfficiency / 1000.0) + 2.0;
        }
      } else {
        // Slowing down to stop or idling
        _throttle = 0;
        if (_speed > 0) {
          _speed = max(0.0, _speed - 3.5 * _speedMultiplier);
          _powerUsage = -25.0; // Light regen while coasting to stop
        } else {
          _speed = 0.0;
          _powerUsage = 0.5; // Accessories idle draw (AC, screens, etc.)
        }
      }

      _speed = min(140.0, max(0.0, _speed));
      _rpm = _speed * 80.0; // Gearless motor RPM (140 km/h = 11,200 RPM)

      // 2. Battery Temperature physics
      final double heatGen = (_powerUsage.abs() / 150.0) * 0.08;
      final double cooling = (_speed > 40 ? 0.02 : 0.01); // active cooling when moving
      _coolantTemp += (heatGen - cooling) * _speedMultiplier;
      _coolantTemp = _coolantTemp.clamp(30.0, 65.0); // Ambient is 30°C

      // 3. Battery SoC consumption/regeneration physics based on battery capacity
      if (_fuelLevel >= 0) {
        final double powerDelta = _powerUsage * (0.1 / 3600.0) * _speedMultiplier;
        const double scaleFactor = 12.0; // scaled for visibility on route
        _fuelLevel -= (powerDelta / state.batteryCapacity) * 100.0 * scaleFactor;
        _fuelLevel = _fuelLevel.clamp(0.0, 100.0);
      }

      // 4. Voltage Sag / Rise physics
      final double baseV = 360.0 + 40.0 * (_fuelLevel / 100.0); // 360V empty to 400V full
      _voltage = baseV - (_powerUsage * 0.08) + (sin(DateTime.now().millisecondsSinceEpoch / 500) * 0.1);
    } else {
      // ICE Vehicle physics
      if (_isMoving) {
        final diff = _targetSpeed - _speed;
        if (diff.abs() > 1.0) {
          if (diff > 0) {
            // Accelerating
            _throttle = min(100.0, _throttle + 5.0);
            _speed += 1.8 * _speedMultiplier;
          } else {
            // Decelerating
            _throttle = 0.0;
            _speed -= 3.5 * _speedMultiplier;
          }
        } else {
          // Cruising
          _speed = _targetSpeed;
          _throttle = max(10.0, (_speed / 2.5).roundToDouble());
        }
      } else {
        // Coasting or idling
        _throttle = 0;
        if (_speed > 0) {
          _speed = max(0.0, _speed - 4.0 * _speedMultiplier);
        } else {
          _speed = 0.0;
        }
      }

      _speed = min(140.0, max(0.0, _speed));

      // Simulate gear-based RPM shifting
      double gearRatio = 1.0;
      if (_speed < 20) {
        gearRatio = 150.0;
      } else if (_speed < 40) {
        gearRatio = 80.0;
      } else if (_speed < 70) {
        gearRatio = 45.0;
      } else if (_speed < 100) {
        gearRatio = 30.0;
      } else {
        gearRatio = 20.0;
      }
      
      if (_speed == 0) {
        _rpm = 800.0; // Idle Engine RPM
        _powerUsage = 0.8; // Fuel Flow at Idle (L/h)
      } else {
        _rpm = 1000.0 + (_speed * gearRatio) + (_throttle * 5.0);
        _rpm = _rpm.clamp(800.0, 5800.0);
        
        if (_throttle == 0) {
          _powerUsage = 0.5; // Decel fuel cut-off
        } else {
          // Dynamic consumption based on speed, efficiency, and throttle load
          _powerUsage = (_speed / state.iceEfficiency) + (_throttle * 0.08) + 0.8;
        }
      }
      _powerUsage = double.parse(_powerUsage.toStringAsFixed(1));

      // Engine Coolant Temp (warms up towards 90°C and stays there)
      if (_coolantTemp < 88.0) {
        _coolantTemp += 0.15 * _speedMultiplier;
      } else {
        // Minor load-based heat fluctuations
        _coolantTemp = 88.0 + (_throttle * 0.05) + (sin(DateTime.now().millisecondsSinceEpoch / 2000) * 0.5);
      }
      _coolantTemp = _coolantTemp.clamp(30.0, 115.0);

      // Gas Fuel depletion based on tank capacity
      if (_fuelLevel >= 0) {
        final double fuelBurned = _powerUsage * (0.1 / 3600.0) * _speedMultiplier;
        const double scaleFactor = 250.0; // scaled depletion for demonstration
        _fuelLevel -= (fuelBurned / state.fuelTankCapacity) * 100.0 * scaleFactor;
        _fuelLevel = _fuelLevel.clamp(0.0, 100.0);
      }

      // Alternator charging voltage (13.8V - 14.2V)
      _voltage = 14.1 + (sin(DateTime.now().millisecondsSinceEpoch / 1000) * 0.05);
    }

    _pushTelemetry();
  }

  void _pushTelemetry() {
    if (state.vehicleType == VehicleType.ev) {
      state.updateTelemetry(
        rpm: _rpm.round(),
        speed: _speed.round(),
        coolantTemp: _coolantTemp,
        fuelLevel: double.parse(_fuelLevel.toStringAsFixed(1)),
        throttle: _throttle.round(),
        voltage: double.parse(_voltage.toStringAsFixed(1)),
        powerUsage: double.parse(_powerUsage.toStringAsFixed(1)),
      );
    } else {
      state.updateTelemetry(
        rpm: _rpm.round(),
        speed: _speed.round(),
        coolantTemp: _coolantTemp,
        fuelLevel: double.parse(_fuelLevel.toStringAsFixed(1)),
        throttle: _throttle.round(),
        voltage: double.parse(_voltage.toStringAsFixed(1)),
        powerUsage: 0.0,
        fuelFlowRate: _powerUsage,
        engineLoad: _throttle,
        sparkAdvance: 10.0 + (_rpm * 0.003) + (_throttle * 0.1),
      );
    }
  }
}
