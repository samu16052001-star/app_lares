import 'dart:async';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

enum OpenRemoteMqttStatus {
  disconnected,
  connecting,
  connected,
  failed,
}

class OpenRemoteMqttState {
  const OpenRemoteMqttState({
    required this.status,
    this.message,
  });

  final OpenRemoteMqttStatus status;
  final String? message;

  bool get isConnected => status == OpenRemoteMqttStatus.connected;
}

class OpenRemoteMqttException implements Exception {
  const OpenRemoteMqttException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OpenRemoteMqttService {
  OpenRemoteMqttService();

  final StreamController<OpenRemoteMqttState> _stateController =
      StreamController<OpenRemoteMqttState>.broadcast();

  MqttServerClient? _client;
  _OpenRemoteMqttConfig? _config;
  Timer? _reconnectTimer;
  bool _connectRequested = false;
  bool _connectInProgress = false;
  bool _disposed = false;
  bool _intentionalDisconnect = false;
  int _reconnectAttempt = 0;

  OpenRemoteMqttState _state = const OpenRemoteMqttState(
    status: OpenRemoteMqttStatus.disconnected,
  );

  Stream<OpenRemoteMqttState> get states => _stateController.stream;

  OpenRemoteMqttState get state => _state;

  bool get isConnected => _state.isConnected;

  Future<void> connect() async {
    if (_disposed || _connectInProgress || isConnected) {
      return;
    }

    _connectRequested = true;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    await _connectOnce(manualAttempt: true);
  }

  Future<bool> publishPm10(double value) async {
    final client = _client;
    final config = _config;

    if (_disposed || client == null || config == null || !isConnected) {
      return false;
    }

    final payload = MqttClientPayloadBuilder()
      ..addString(_formatJsonNumber(value));

    try {
      client.publishMessage(
        config.topic,
        MqttQos.atMostOnce,
        payload.payload!,
        retain: false,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _connectRequested = false;
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final client = _client;
    _client = null;
    client?.disconnect();
    await _stateController.close();
  }

  Future<void> _connectOnce({required bool manualAttempt}) async {
    if (_disposed || _connectInProgress) {
      return;
    }

    _connectInProgress = true;
    _emit(
      const OpenRemoteMqttState(
        status: OpenRemoteMqttStatus.connecting,
        message: 'Connecting to OpenRemote...',
      ),
    );

    try {
      _config ??= await _OpenRemoteMqttConfig.load();
      final config = _config!;
      final client = MqttServerClient(config.host, config.clientId)
        ..port = config.port
        ..keepAlivePeriod = 30
        ..autoReconnect = false
        ..secure = config.useTls
        ..logging(on: false)
        ..onDisconnected = _handleDisconnected;

      client.setProtocolV311();

      if (config.useTls) {
        client.securityContext = SecurityContext.defaultContext;
        client.onBadCertificate = (_) => config.tlsInsecure;
      }

      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(config.clientId)
          .authenticateAs(config.username, config.password)
          .startClean()
          .withWillQos(MqttQos.atMostOnce);

      _intentionalDisconnect = false;
      _client?.disconnect();
      _client = client;

      await client.connect().timeout(const Duration(seconds: 12));

      if (_disposed) {
        client.disconnect();
        return;
      }

      final connected =
          client.connectionStatus?.state == MqttConnectionState.connected;
      if (!connected) {
        final returnCode = client.connectionStatus?.returnCode;
        client.disconnect();
        throw OpenRemoteMqttException(
          _messageForReturnCode(returnCode),
        );
      }

      _reconnectAttempt = 0;
      _emit(
        const OpenRemoteMqttState(
          status: OpenRemoteMqttStatus.connected,
          message: 'Connected to OpenRemote',
        ),
      );
    } on OpenRemoteMqttException catch (error) {
      _handleConnectError(error.message, manualAttempt: manualAttempt);
    } on SocketException {
      _handleConnectError(
        'OpenRemote broker is not reachable.',
        manualAttempt: manualAttempt,
      );
    } on HandshakeException {
      _handleConnectError(
        'OpenRemote TLS verification failed.',
        manualAttempt: manualAttempt,
      );
    } catch (error) {
      _handleConnectError(
        _safeConnectionMessage(error),
        manualAttempt: manualAttempt,
      );
    } finally {
      _connectInProgress = false;
    }
  }

  void _handleConnectError(String message, {required bool manualAttempt}) {
    if (_disposed) {
      return;
    }

    _client?.disconnect();
    _client = null;
    _emit(
      OpenRemoteMqttState(
        status: OpenRemoteMqttStatus.failed,
        message: manualAttempt ? message : 'OpenRemote disconnected.',
      ),
    );

    if (!manualAttempt && _connectRequested) {
      _scheduleReconnect();
    }
  }

  void _handleDisconnected() {
    if (_disposed || _intentionalDisconnect) {
      return;
    }

    _client = null;
    _emit(
      const OpenRemoteMqttState(
        status: OpenRemoteMqttStatus.failed,
        message: 'OpenRemote disconnected.',
      ),
    );

    if (_connectRequested) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _connectInProgress || _reconnectTimer != null) {
      return;
    }

    final delay = _reconnectDelay(_reconnectAttempt);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || !_connectRequested || isConnected) {
        return;
      }
      unawaited(_connectOnce(manualAttempt: false));
    });
  }

  Duration _reconnectDelay(int attempt) {
    const seconds = [1, 2, 5, 10, 30];
    return Duration(seconds: seconds[attempt.clamp(0, seconds.length - 1)]);
  }

  void _emit(OpenRemoteMqttState state) {
    _state = state;
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  String _formatJsonNumber(double value) {
    if (value == value.truncateToDouble()) {
      return value.toInt().toString();
    }

    return value.toString();
  }

  String _safeConnectionMessage(Object error) {
    final text = error.toString().toLowerCase();

    if (text.contains('auth') ||
        text.contains('not authorized') ||
        text.contains('bad username') ||
        text.contains('password')) {
      return 'OpenRemote authentication was rejected.';
    }

    if (text.contains('certificate') || text.contains('handshake')) {
      return 'OpenRemote TLS verification failed.';
    }

    if (text.contains('timed out') || text.contains('timeout')) {
      return 'OpenRemote connection timed out.';
    }

    return 'Could not connect to OpenRemote.';
  }

  String _messageForReturnCode(MqttConnectReturnCode? returnCode) {
    return switch (returnCode) {
      MqttConnectReturnCode.connectionAccepted =>
        'Connected to OpenRemote',
      MqttConnectReturnCode.unacceptedProtocolVersion =>
        'OpenRemote rejected the MQTT protocol version.',
      MqttConnectReturnCode.identifierRejected =>
        'OpenRemote rejected the MQTT client ID.',
      MqttConnectReturnCode.brokerUnavailable =>
        'OpenRemote broker is unavailable.',
      MqttConnectReturnCode.badUsernameOrPassword =>
        'OpenRemote authentication was rejected.',
      MqttConnectReturnCode.notAuthorized =>
        'OpenRemote authentication was rejected.',
      _ => 'OpenRemote connection failed.',
    };
  }
}

class _OpenRemoteMqttConfig {
  const _OpenRemoteMqttConfig({
    required this.host,
    required this.port,
    required this.useTls,
    required this.tlsInsecure,
    required this.realm,
    required this.clientId,
    required this.username,
    required this.password,
    required this.assetId,
    required this.attribute,
  });

  final String host;
  final int port;
  final bool useTls;
  final bool tlsInsecure;
  final String realm;
  final String clientId;
  final String username;
  final String password;
  final String assetId;
  final String attribute;

  String get topic =>
      '$realm/$clientId/writeattributevalue/$attribute/$assetId';

  static Future<_OpenRemoteMqttConfig> load() async {
    // Local .env credentials are acceptable only for this internal prototype,
    // not for a publicly distributed app.
    try {
      if (!dotenv.isInitialized) {
        await dotenv.load(fileName: '.env');
      }
    } catch (_) {
      throw const OpenRemoteMqttException(
        'OpenRemote configuration file is missing.',
      );
    }

    final host = _required('OR_HOST');
    final port = _parsePort(_required('OR_PORT'));
    final useTls = _parseBool(_read('OR_USE_TLS', fallback: 'false'));
    final tlsInsecure = _parseBool(
      _read('OR_TLS_INSECURE', fallback: 'false'),
    );
    final realm = _required('OR_REALM');
    final clientPrefix = _requiredAny([
      'OR_CLIENT_SUFFIX',
      'OR_CLIENT_PREFIX',
    ]);
    final rawUsername = _required('OR_USERNAME');
    final password = _required('OR_PASSWORD');
    final assetId = _required('OR_ASSET_ID');
    final attribute = _required('OR_ATTRIBUTE');
    final installationId = await _installationId();

    return _OpenRemoteMqttConfig(
      host: host,
      port: port,
      useTls: useTls,
      tlsInsecure: tlsInsecure,
      realm: realm,
      clientId: '$clientPrefix-$installationId',
      username: '$realm:$rawUsername',
      password: password,
      assetId: assetId,
      attribute: attribute,
    );
  }

  static String _required(String key) {
    final value = _read(key);
    if (value == null || value.isEmpty || value.startsWith('<')) {
      throw OpenRemoteMqttException(
        'OpenRemote configuration is incomplete: $key is missing.',
      );
    }

    return value;
  }

  static String _requiredAny(List<String> keys) {
    for (final key in keys) {
      final value = _read(key);
      if (value != null && value.isNotEmpty && !value.startsWith('<')) {
        return value;
      }
    }

    throw OpenRemoteMqttException(
      'OpenRemote configuration is incomplete: ${keys.join(' or ')} is missing.',
    );
  }

  static String? _read(String key, {String? fallback}) {
    final value = _stripInlineComment(dotenv.env[key])?.trim();
    if (value == null || value.isEmpty) {
      return fallback;
    }

    return value;
  }

  static String? _stripInlineComment(String? value) {
    if (value == null) {
      return null;
    }

    final commentStart = value.indexOf(' #');
    if (commentStart == -1) {
      return value;
    }

    return value.substring(0, commentStart);
  }

  static int _parsePort(String value) {
    final port = int.tryParse(value);
    if (port == null || port <= 0 || port > 65535) {
      throw const OpenRemoteMqttException(
        'OpenRemote MQTT port is invalid.',
      );
    }

    return port;
  }

  static bool _parseBool(String? value) {
    return value?.trim().toLowerCase() == 'true';
  }

  static Future<String> _installationId() async {
    const key = 'openremote_installation_id';
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final generated = const Uuid().v4();
    await prefs.setString(key, generated);
    return generated;
  }
}
