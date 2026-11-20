import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

class GpsLocationService {
  static const EventChannel _androidPositions =
      EventChannel('app_lares/acquisition_location');
  static const MethodChannel _androidRuntime =
      MethodChannel('app_lares/acquisition_foreground_service');
  final StreamController<Position> _livePositionController =
      StreamController<Position>.broadcast(sync: true);
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<ServiceStatus>? _serviceStatusSubscription;
  Position? _latestPosition;
  bool _isStarted = false;
  bool _locationServicesEnabled = false;
  bool _hasLocationPermission = false;
  String? _statusMessage;
  Future<void>? _androidResumeFuture;

  String? get statusMessage => _statusMessage;

  Stream<Position> get livePositions => _livePositionController.stream;

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
    _statusMessage = null;
    try {
      _locationServicesEnabled = await Geolocator.isLocationServiceEnabled();
      if (!_locationServicesEnabled) {
        _statusMessage =
            'Location services are disabled. GPS coordinates will be saved as NA.';
        return;
      }

      _hasLocationPermission = await _ensurePermission();
      if (!_hasLocationPermission) {
        _statusMessage =
            'Location permission denied. GPS coordinates will be saved as NA.';
        return;
      }

      await _loadLastKnownPosition();
      _listenToServiceStatus();
      _listenToPositionUpdates();
    } catch (_) {
      _locationServicesEnabled = false;
      _hasLocationPermission = false;
      _latestPosition = null;
      _statusMessage = 'GPS is unavailable. GPS coordinates will be saved as NA.';
    }
  }

  Future<void> stop() async {
    _isStarted = false;
    await _positionSubscription?.cancel();
    await _serviceStatusSubscription?.cancel();
    _positionSubscription = null;
    _serviceStatusSubscription = null;
  }

  Future<void> resumeAfterAndroidActivityAttached() async {
    if (!Platform.isAndroid || !_isStarted || _positionSubscription != null) {
      return;
    }
    final pending = _androidResumeFuture;
    if (pending != null) return pending;
    final operation = _resumeAndroidGps();
    _androidResumeFuture = operation;
    try {
      await operation;
    } finally {
      _androidResumeFuture = null;
    }
  }

  Future<void> _resumeAndroidGps() async {
    if (await _androidRuntime.invokeMethod<bool>('isActivityAttached') != true ||
        !_isStarted || _positionSubscription != null) {
      return;
    }
    await _serviceStatusSubscription?.cancel();
    _serviceStatusSubscription = null;
    if (!_isStarted) return;
    _isStarted = false;
    await start();
  }

  Future<void> dispose() async {
    await stop();
    await _livePositionController.close();
  }

  Future<bool> _ensurePermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // A sticky Android service restart has no Activity for a permission dialog.
      if (Platform.isAndroid &&
          await _androidRuntime.invokeMethod<bool>('isActivityAttached') != true) {
        return false;
      }
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
          _statusMessage =
              'Location services are disabled. GPS coordinates will be saved as NA.';
        } else if (_hasLocationPermission) {
          _statusMessage = null;
        }
      },
      onError: (_) {
        _locationServicesEnabled = false;
        _latestPosition = null;
        _statusMessage = 'GPS is unavailable. GPS coordinates will be saved as NA.';
      },
    );
  }

  void _listenToPositionUpdates() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );

    final positions = Platform.isAndroid
        ? _androidPositions.receiveBroadcastStream(<String, Object>{
            'accuracy': locationSettings.accuracy.index,
            'distanceFilter': locationSettings.distanceFilter,
          }).map((event) => Position.fromMap(Map<String, dynamic>.from(event as Map)))
        : Geolocator.getPositionStream(locationSettings: locationSettings);
    _positionSubscription = positions.listen(
      (position) {
        _latestPosition = position;
        _statusMessage = null;
        _livePositionController.add(position);
      },
      onError: (_) {
        _latestPosition = null;
        if (Platform.isAndroid) {
          _statusMessage = 'GPS is temporarily unavailable. GPS coordinates will be saved as NA.';
        }
      },
    );
  }
}
