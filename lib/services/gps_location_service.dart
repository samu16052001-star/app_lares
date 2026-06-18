import 'dart:async';

import 'package:geolocator/geolocator.dart';

class GpsLocationService {
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<ServiceStatus>? _serviceStatusSubscription;
  Position? _latestPosition;
  bool _isStarted = false;
  bool _locationServicesEnabled = false;
  bool _hasLocationPermission = false;

  String get currentCoordinates {
    final position = _latestPosition;
    if (!_locationServicesEnabled ||
        !_hasLocationPermission ||
        position == null) {
      return 'NA';
    }

    return '${position.latitude},${position.longitude}';
  }

  Future<void> start() async {
    if (_isStarted) {
      return;
    }

    _isStarted = true;
    try {
      _locationServicesEnabled = await Geolocator.isLocationServiceEnabled();
      if (!_locationServicesEnabled) {
        return;
      }

      _hasLocationPermission = await _ensurePermission();
      if (!_hasLocationPermission) {
        return;
      }

      await _loadLastKnownPosition();
      _listenToServiceStatus();
      _listenToPositionUpdates();
    } catch (_) {
      _locationServicesEnabled = false;
      _hasLocationPermission = false;
      _latestPosition = null;
    }
  }

  Future<void> stop() async {
    _isStarted = false;
    await _positionSubscription?.cancel();
    await _serviceStatusSubscription?.cancel();
    _positionSubscription = null;
    _serviceStatusSubscription = null;
  }

  Future<void> dispose() async {
    await stop();
  }

  Future<bool> _ensurePermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Future<void> _loadLastKnownPosition() async {
    try {
      _latestPosition = await Geolocator.getLastKnownPosition();
    } catch (_) {
      _latestPosition = null;
    }
  }

  void _listenToServiceStatus() {
    _serviceStatusSubscription = Geolocator.getServiceStatusStream().listen(
      (status) {
        _locationServicesEnabled = status == ServiceStatus.enabled;
        if (!_locationServicesEnabled) {
          _latestPosition = null;
        }
      },
      onError: (_) {
        _locationServicesEnabled = false;
        _latestPosition = null;
      },
    );
  }

  void _listenToPositionUpdates() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) {
        _latestPosition = position;
      },
      onError: (_) {
        _latestPosition = null;
      },
    );
  }
}
