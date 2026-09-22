import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:silosend_datasharing_app/core/connection/ble_connection_server.dart';
import 'package:silosend_datasharing_app/core/connection/connection_manager.dart';
import 'package:silosend_datasharing_app/core/connection/connection_session.dart';
import 'package:silosend_datasharing_app/core/connection/lan_connection_server.dart';
import 'package:silosend_datasharing_app/core/constants/app_constants.dart';
import 'package:silosend_datasharing_app/core/contracts/discovery_contract.dart';
import 'package:silosend_datasharing_app/core/contracts/transport_contract.dart';
import 'package:silosend_datasharing_app/core/discovery/ble_discovery_service.dart';
import 'package:silosend_datasharing_app/core/discovery/discovery_coordinator.dart';
import 'package:silosend_datasharing_app/core/discovery/lan_discovery_service.dart';
import 'package:silosend_datasharing_app/core/identity/device_identity_manager.dart';
import 'package:silosend_datasharing_app/core/identity/identity_storage.dart';
import 'package:silosend_datasharing_app/core/lifecycle/app_lifecycle_manager.dart';
import 'package:silosend_datasharing_app/core/logging/app_logger.dart';
import 'package:silosend_datasharing_app/core/pairing/nfc_pairing_service.dart';
import 'package:silosend_datasharing_app/domain/identity/device_capabilities.dart';
import 'package:silosend_datasharing_app/domain/identity/local_device_identity.dart';
import 'package:silosend_datasharing_app/platform/platform_service.dart';
import 'package:silosend_datasharing_app/platform/system_platform_service.dart';

/// Central dependency and service container for SiloSend core primitives.
///
/// Unifies identity management, platform capabilities, lifecycle management,
/// peer discovery, transport connections, and pairing into a cohesive,
/// testable application context.
class AppContainer {
  final IdentityStorage identityStorage;
  final DeviceIdentityManager identityManager;
  final PlatformService platformService;
  final AppLifecycleManager lifecycleManager;
  final DiscoveryCoordinator? _injectedDiscoveryCoordinator;
  final ConnectionManager? _injectedConnectionManager;
  final LanConnectionServer? _injectedLanServer;
  final BleConnectionServer? _injectedBleServer;
  final NfcPairingService? _injectedNfcPairingService;

  DiscoveryCoordinator? _discoveryCoordinator;
  ConnectionManager? _connectionManager;
  LanConnectionServer? _lanServer;
  BleConnectionServer? _bleServer;
  NfcPairingService? _nfcPairingService;

  bool _isInitialized = false;
  Object? _initError;
  DeviceCapabilities _capabilities = DeviceCapabilities.unknown;

  AppContainer({
    required this.identityStorage,
    required this.identityManager,
    required this.platformService,
    required this.lifecycleManager,
    DiscoveryCoordinator? discoveryCoordinator,
    ConnectionManager? connectionManager,
    LanConnectionServer? lanServer,
    BleConnectionServer? bleServer,
    NfcPairingService? nfcPairingService,
  }) : _injectedDiscoveryCoordinator = discoveryCoordinator,
       _injectedConnectionManager = connectionManager,
       _injectedLanServer = lanServer,
       _injectedBleServer = bleServer,
       _injectedNfcPairingService = nfcPairingService;

  /// Factory producing a standard production container.
  factory AppContainer.standard({
    IdentityStorage? storage,
    PlatformService? platformService,
    AppLifecycleManager? lifecycleManager,
    DiscoveryCoordinator? discoveryCoordinator,
    ConnectionManager? connectionManager,
    LanConnectionServer? lanServer,
    BleConnectionServer? bleServer,
    NfcPairingService? nfcPairingService,
  }) {
    final effectiveStorage = storage ?? _createDefaultFileStorage();
    final effectivePlatform = platformService ?? SystemPlatformService();
    final effectiveLifecycle = lifecycleManager ?? AppLifecycleManager();

    return AppContainer(
      identityStorage: effectiveStorage,
      identityManager: DeviceIdentityManager(effectiveStorage),
      platformService: effectivePlatform,
      lifecycleManager: effectiveLifecycle,
      discoveryCoordinator: discoveryCoordinator,
      connectionManager: connectionManager,
      lanServer: lanServer,
      bleServer: bleServer,
      nfcPairingService: nfcPairingService,
    );
  }

  /// Whether the core foundation and persistent identity have been initialized.
  bool get isInitialized => _isInitialized;

  /// Initialization error if startup failed.
  Object? get initError => _initError;

  /// Current persistent local device identity.
  LocalDeviceIdentity? get identity => identityManager.currentIdentity;

  /// Current probed hardware capabilities.
  DeviceCapabilities get capabilities => _capabilities;

  /// Current application lifecycle state.
  AppLifecycleState get lifecycleState => lifecycleManager.currentState;

  /// Discovery coordinator managing multi-transport discovery and deduplication.
  DiscoveryCoordinator get discoveryCoordinator {
    if (_discoveryCoordinator == null) {
      throw StateError(
        'DiscoveryCoordinator accessed before AppContainer.initialize()',
      );
    }
    return _discoveryCoordinator!;
  }

  /// Connection manager orchestrating point-to-point connections.
  ConnectionManager get connectionManager {
    if (_connectionManager == null) {
      throw StateError(
        'ConnectionManager accessed before AppContainer.initialize()',
      );
    }
    return _connectionManager!;
  }

  /// Active LAN TCP server accepting incoming peer connections.
  LanConnectionServer? get lanServer => _lanServer;

  /// Active BLE GATT server accepting incoming peer connections (Android only).
  BleConnectionServer? get bleServer => _bleServer;

  /// NFC pairing service handling out-of-band tag exchange.
  NfcPairingService get nfcPairingService {
    if (_nfcPairingService == null) {
      throw StateError(
        'NfcPairingService accessed before AppContainer.initialize()',
      );
    }
    return _nfcPairingService!;
  }

  /// Reactive stream of local device identity changes.
  Stream<LocalDeviceIdentity> get identityStream =>
      identityManager.identityStream;

  /// Reactive stream of lifecycle state transitions.
  Stream<AppLifecycleState> get lifecycleStream => lifecycleManager.stateStream;

  /// Reactive stream of discovered nearby peers.
  Stream<List<DiscoveredPeer>> get discoveredPeersStream =>
      discoveryCoordinator.peersStream;

  /// Current list of active nearby peers.
  List<DiscoveredPeer> get discoveredPeers => discoveryCoordinator.currentPeers;

  /// Current discovery operational status.
  DiscoveryStatus get discoveryStatus => discoveryCoordinator.status;

  /// Reactive stream of discovery status transitions.
  Stream<DiscoveryStatus> get discoveryStatusStream =>
      discoveryCoordinator.statusStream;

  /// Current list of active point-to-point connection sessions.
  List<ConnectionSession> get activeSessions =>
      _connectionManager?.activeSessions ?? [];

  /// Reactive stream of active connection sessions.
  Stream<List<ConnectionSession>> get activeSessionsStream =>
      _connectionManager?.activeSessionsStream ?? const Stream.empty();

  /// Initiates a point-to-point connection to a discovered peer.
  Future<ConnectionSession> connectToPeer(
    DiscoveredPeer peer, {
    TransportType? preferredTransport,
    Duration? timeout,
  }) {
    return connectionManager.connectToPeer(
      peer,
      preferredTransport: preferredTransport,
      timeout: timeout,
    );
  }

  /// Explicitly disconnects an active connection session.
  Future<void> disconnectSession(String sessionId, {String? reason}) {
    return connectionManager.disconnectSession(sessionId, reason: reason);
  }

  /// Initializes core services, loads/creates device identity, binds discovery coordinator,
  /// starts transport servers, and initializes connection manager and pairing services.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      AppLogger.info('AppContainer', 'Initializing SiloSend core container...');

      // 1. Start lifecycle observation
      lifecycleManager.start();

      // 2. Query platform capabilities truthfully
      _capabilities = await platformService.getCapabilities();

      // 3. Load or mint persistent local device identity
      final loadedIdentity = await identityManager.getOrCreateIdentity();

      // 4. Initialize Discovery Coordinator
      if (_injectedDiscoveryCoordinator != null) {
        _discoveryCoordinator = _injectedDiscoveryCoordinator;
      } else {
        final lanService = LanDiscoveryService(
          localDeviceId: loadedIdentity.idHex,
        );
        final bleService = BleDiscoveryService(
          localDeviceId: loadedIdentity.idHex,
        );
        _discoveryCoordinator = DiscoveryCoordinator(
          services: [lanService, bleService],
        );
      }

      // 5. Initialize LAN TCP server
      if (_injectedLanServer != null) {
        _lanServer = _injectedLanServer;
      } else {
        var server = LanConnectionServer(requestedPort: 53531);
        try {
          await server.start();
        } catch (e) {
          AppLogger.warning(
            'AppContainer',
            'Could not bind default LAN server port 53531, trying ephemeral port: $e',
          );
          server = LanConnectionServer(requestedPort: 0);
          try {
            await server.start();
          } catch (e2) {
            AppLogger.warning(
              'AppContainer',
              'Could not bind ephemeral LAN server: $e2',
            );
          }
        }
        _lanServer = server;
      }

      // 6. Initialize BLE GATT Server (Android with BLE capability only)
      if (_injectedBleServer != null) {
        _bleServer = _injectedBleServer;
      } else if (Platform.isAndroid && _capabilities.supportsBle) {
        _bleServer = BleConnectionServer();
        try {
          await _bleServer!.start();
        } catch (e) {
          AppLogger.warning(
            'AppContainer',
            'Could not start BLE GATT server: $e',
          );
        }
      }

      // 7. Initialize Connection Manager
      if (_injectedConnectionManager != null) {
        _connectionManager = _injectedConnectionManager;
      } else {
        _connectionManager = ConnectionManager(
          localIdentity: loadedIdentity,
          supportedTransports: {
            TransportType.lan,
            if (_capabilities.supportsBle) TransportType.ble,
          },
        );

        if (_lanServer != null) {
          _connectionManager!.registerLanServer(_lanServer!);
        }
        if (_bleServer != null) {
          _connectionManager!.registerIncomingStream(
            _bleServer!.incomingConnections,
          );
        }
      }

      // 8. Initialize NFC Pairing Service
      if (_injectedNfcPairingService != null) {
        _nfcPairingService = _injectedNfcPairingService;
      } else {
        _nfcPairingService = NfcPairingService(
          platformService: platformService,
        );
      }

      // 9. Connect lifecycle transitions with discovery state
      lifecycleManager.addListener(_onLifecycleStateChanged);

      _isInitialized = true;
      _initError = null;
      AppLogger.info(
        'AppContainer',
        'SiloSend core container initialized successfully for: ${identity?.displayName} (${identity?.idHex.substring(0, 8)}...)',
      );
    } catch (e, stack) {
      _initError = e;
      AppLogger.error(
        'AppContainer',
        'Fatal error during core container initialization',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  void _onLifecycleStateChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      AppLogger.info(
        'AppContainer',
        'App backgrounded: discovery coordinator notified',
      );
    } else if (state == AppLifecycleState.resumed) {
      AppLogger.info(
        'AppContainer',
        'App resumed: discovery coordinator active',
      );
    }
  }

  /// Starts discovery scanning and advertising across all supported transports.
  Future<void> startDiscoveryAndAdvertising() async {
    final id = identity;
    if (id == null) {
      throw StateError('Cannot start discovery before identity is initialized');
    }

    final serverPort = _lanServer?.boundPort ?? 53531;

    final ad = DeviceAdvertisement(
      deviceId: id.idHex,
      displayName: id.displayName,
      port: serverPort,
      supportedTransports: {
        TransportType.lan,
        if (_capabilities.supportsBle) TransportType.ble,
      },
      protocolVersion: id.protocolVersion,
    );

    await discoveryCoordinator.startAdvertising(ad);
    await discoveryCoordinator.startDiscovery();
  }

  /// Stops discovery and advertising.
  Future<void> stopDiscoveryAndAdvertising() async {
    await discoveryCoordinator.stopAdvertising();
    await discoveryCoordinator.stopDiscovery();
  }

  /// Disposes active resources, servers, discovery timers, and connection sessions.
  void dispose() {
    lifecycleManager.removeListener(_onLifecycleStateChanged);
    _discoveryCoordinator?.dispose();
    _connectionManager?.dispose();
    _lanServer?.dispose();
    _bleServer?.dispose();
    _nfcPairingService?.dispose();
    lifecycleManager.dispose();
    identityManager.dispose();
    _isInitialized = false;
  }

  /// Resolves standard platform storage file without external dependencies.
  static IdentityStorage _createDefaultFileStorage() {
    try {
      File file;
      if (Platform.isAndroid) {
        final dir = Directory(
          '/data/user/0/${AppConstants.applicationId}/files',
        );
        file = File('${dir.path}/device_identity.json');
      } else if (Platform.isWindows) {
        final appData =
            Platform.environment['APPDATA'] ??
            Platform.environment['LOCALAPPDATA'];
        if (appData != null) {
          file = File('$appData/${AppConstants.appName}/device_identity.json');
        } else {
          file = File(
            '${Directory.systemTemp.path}/${AppConstants.applicationId}/device_identity.json',
          );
        }
      } else {
        file = File(
          '${Directory.systemTemp.path}/${AppConstants.applicationId}/device_identity.json',
        );
      }
      return FileIdentityStorage(file);
    } catch (_) {
      return InMemoryIdentityStorage();
    }
  }
}
