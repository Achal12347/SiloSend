import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:vayu/core/capabilities/capability_coordinator.dart';
import 'package:vayu/core/connection/ble_connection_server.dart';
import 'package:vayu/core/connection/connection_manager.dart';
import 'package:vayu/core/connection/connection_session.dart';
import 'package:vayu/core/connection/lan_connection_server.dart';
import 'package:vayu/core/constants/app_constants.dart';
import 'package:vayu/core/constants/app_paths.dart';
import 'package:vayu/core/contacts/my_card_store.dart';
import 'package:vayu/core/contracts/discovery_contract.dart';
import 'package:vayu/core/contracts/transfer_contract.dart';
import 'package:vayu/core/contracts/transport_contract.dart';
import 'package:vayu/core/discovery/ble_discovery_service.dart';
import 'package:vayu/core/discovery/discovery_coordinator.dart';
import 'package:vayu/core/discovery/lan_discovery_service.dart';
import 'package:vayu/core/identity/device_identity_manager.dart';
import 'package:vayu/core/identity/device_name_generator.dart';
import 'package:vayu/core/identity/identity_storage.dart';
import 'package:vayu/core/lifecycle/app_lifecycle_manager.dart';
import 'package:vayu/core/logging/app_logger.dart';
import 'package:vayu/core/pairing/nfc_pairing_service.dart';
import 'package:vayu/core/security/aead_cipher.dart';
import 'package:vayu/core/security/crypto_service.dart';
import 'package:vayu/core/security/trust_record_storage.dart';
import 'package:vayu/core/pairing/local_hotspot_service.dart';
import 'package:vayu/core/pairing/pairing_coordinator.dart';
import 'package:vayu/platform/android_nfc_adapter.dart';
import 'package:vayu/platform/contact_picker.dart';
import 'package:vayu/platform/android_secure_key_store.dart';
import 'package:vayu/core/security/peer_trust_store.dart';
import 'package:vayu/core/security/secure_key_store.dart';
import 'package:vayu/core/battery/battery_snapshot.dart';
import 'package:vayu/core/battery/system_battery_provider.dart';
import 'package:vayu/core/contracts/battery_contract.dart';
import 'package:vayu/core/settings/user_settings.dart';
import 'package:vayu/core/contracts/transport_selector_contract.dart';
import 'package:vayu/core/security/secure_session_impl.dart';
import 'package:vayu/core/security/secure_session_manager.dart';
import 'package:vayu/core/contracts/file_picker_contract.dart';
import 'package:vayu/core/contracts/storage_contract.dart';
import 'package:vayu/core/file/system_file_picker_service.dart';
import 'package:vayu/core/file/system_storage_service.dart';
import 'package:vayu/core/session/session_lifecycle_policy.dart';
import 'package:vayu/core/contracts/transfer_keep_alive_contract.dart';
import 'package:vayu/core/transfer/transfer_keep_alive_controller.dart';
import 'package:vayu/platform/android_transfer_keep_alive.dart';
import 'package:vayu/core/state/app_orchestrator.dart';
import 'package:vayu/core/transfer/file_sharing_coordinator.dart';
import 'package:vayu/core/transfer/transfer_engine_impl.dart';
import 'package:vayu/core/transfer/transfer_history.dart';
import 'package:vayu/core/transfer/transfer_stats.dart';
import 'package:vayu/core/transport/smart_transport_selector_impl.dart';
import 'package:vayu/domain/identity/device_capabilities.dart';
import 'package:vayu/domain/identity/system_capabilities.dart';
import 'package:vayu/domain/contacts/vayu_card.dart';
import 'package:vayu/domain/identity/local_device_identity.dart';
import 'package:vayu/domain/pairing/pairing_payload.dart';
import 'package:vayu/domain/security/crypto_identity_keypair.dart';
import 'package:vayu/platform/platform_service.dart';
import 'package:vayu/platform/system_platform_service.dart';

/// Central dependency and service container for Vayu core primitives.
///
/// Unifies identity management, platform capabilities, lifecycle management,
/// peer discovery, transport connections, and pairing into a cohesive,
/// testable application context.
class AppContainer {
  final IdentityStorage identityStorage;
  final SettingsStorage settingsStorage;
  final DeviceIdentityManager identityManager;
  final PlatformService platformService;
  final AppLifecycleManager lifecycleManager;
  final DiscoveryCoordinator? _injectedDiscoveryCoordinator;
  final ConnectionManager? _injectedConnectionManager;
  final LanConnectionServer? _injectedLanServer;
  final BleConnectionServer? _injectedBleServer;
  final NfcPairingService? _injectedNfcPairingService;
  final CryptoService? _injectedCryptoService;
  final SecureKeyStore? _injectedSecureKeyStore;
  final PeerTrustStore? _injectedPeerTrustStore;
  final SecureSessionManager? _injectedSecureSessionManager;
  final TransferEngine? _injectedTransferEngine;
  final BatteryStateProvider? _injectedBatteryProvider;
  final TransportSelector? _injectedTransportSelector;
  final FilePickerService? _injectedFilePickerService;
  final StorageService? _injectedStorageService;
  final SessionLifecyclePolicy? _injectedSessionLifecyclePolicy;
  final FileSharingCoordinator? _injectedFileSharingCoordinator;
  final CapabilityCoordinator? _injectedCapabilityCoordinator;

  DiscoveryCoordinator? _discoveryCoordinator;
  CapabilityCoordinator? _capabilityCoordinator;
  ConnectionManager? _connectionManager;
  LanConnectionServer? _lanServer;
  BleConnectionServer? _bleServer;
  NfcPairingService? _nfcPairingService;
  CryptoService? _cryptoService;
  SecureKeyStore? _secureKeyStore;
  PeerTrustStore? _peerTrustStore;
  SecureSessionManager? _secureSessionManager;
  TransferEngine? _transferEngine;
  TransferHistory? _transferHistory;
  MyCardStore? _myCardStore;
  VayuCard? _myCard;
  final StreamController<VayuCard?> _myCardController =
      StreamController<VayuCard?>.broadcast();
  BatteryStateProvider? _batteryProvider;
  TransportSelector? _transportSelector;
  FilePickerService? _filePickerService;
  StorageService? _storageService;
  SessionLifecyclePolicy? _sessionLifecyclePolicy;
  FileSharingCoordinator? _fileSharingCoordinator;
  PairingCoordinator? _pairingCoordinator;
  LocalHotspotService? _hotspotService;
  AppOrchestrator? _orchestrator;

  UserSettings _userSettings = const UserSettings();
  final StreamController<UserSettings> _userSettingsController =
      StreamController<UserSettings>.broadcast();

  bool _isInitialized = false;
  Object? _initError;
  DeviceCapabilities _capabilities = DeviceCapabilities.unknown;
  SystemCapabilities _systemCapabilities = SystemCapabilities.baseline();
  final StreamController<SystemCapabilities> _capabilitiesController =
      StreamController<SystemCapabilities>.broadcast();

  AppContainer({
    required this.identityStorage,
    SettingsStorage? settingsStorage,
    required this.identityManager,
    required this.platformService,
    required this.lifecycleManager,
    DiscoveryCoordinator? discoveryCoordinator,
    ConnectionManager? connectionManager,
    LanConnectionServer? lanServer,
    BleConnectionServer? bleServer,
    NfcPairingService? nfcPairingService,
    CryptoService? cryptoService,
    SecureKeyStore? secureKeyStore,
    PeerTrustStore? peerTrustStore,
    SecureSessionManager? secureSessionManager,
    TransferEngine? transferEngine,
    BatteryStateProvider? batteryProvider,
    TransportSelector? transportSelector,
    FilePickerService? filePickerService,
    StorageService? storageService,
    SessionLifecyclePolicy? sessionLifecyclePolicy,
    FileSharingCoordinator? fileSharingCoordinator,
    CapabilityCoordinator? capabilityCoordinator,
  }) : settingsStorage = settingsStorage ?? InMemorySettingsStorage(),
       _injectedDiscoveryCoordinator = discoveryCoordinator,
       _injectedConnectionManager = connectionManager,
       _injectedLanServer = lanServer,
       _injectedBleServer = bleServer,
       _injectedNfcPairingService = nfcPairingService,
       _injectedCryptoService = cryptoService,
       _injectedSecureKeyStore = secureKeyStore,
       _injectedPeerTrustStore = peerTrustStore,
       _injectedSecureSessionManager = secureSessionManager,
       _injectedTransferEngine = transferEngine,
       _injectedBatteryProvider = batteryProvider,
       _injectedTransportSelector = transportSelector,
       _injectedFilePickerService = filePickerService,
       _injectedStorageService = storageService,
       _injectedSessionLifecyclePolicy = sessionLifecyclePolicy,
       _injectedFileSharingCoordinator = fileSharingCoordinator,
       _injectedCapabilityCoordinator = capabilityCoordinator;

  /// Factory producing a standard production container.
  factory AppContainer.standard({
    IdentityStorage? storage,
    SettingsStorage? settingsStorage,
    PlatformService? platformService,
    AppLifecycleManager? lifecycleManager,
    DiscoveryCoordinator? discoveryCoordinator,
    ConnectionManager? connectionManager,
    LanConnectionServer? lanServer,
    BleConnectionServer? bleServer,
    NfcPairingService? nfcPairingService,
    CryptoService? cryptoService,
    SecureKeyStore? secureKeyStore,
    PeerTrustStore? peerTrustStore,
    SecureSessionManager? secureSessionManager,
    TransferEngine? transferEngine,
    BatteryStateProvider? batteryProvider,
    TransportSelector? transportSelector,
    FilePickerService? filePickerService,
    StorageService? storageService,
    SessionLifecyclePolicy? sessionLifecyclePolicy,
    FileSharingCoordinator? fileSharingCoordinator,
    CapabilityCoordinator? capabilityCoordinator,
  }) {
    final effectiveStorage = storage ?? _createDefaultFileStorage();
    final effectiveSettings =
        settingsStorage ?? _createDefaultSettingsStorage();
    final effectivePlatform = platformService ?? SystemPlatformService();
    final effectiveLifecycle = lifecycleManager ?? AppLifecycleManager();

    return AppContainer(
      identityStorage: effectiveStorage,
      settingsStorage: effectiveSettings,
      identityManager: DeviceIdentityManager(effectiveStorage),
      platformService: effectivePlatform,
      lifecycleManager: effectiveLifecycle,
      discoveryCoordinator: discoveryCoordinator,
      connectionManager: connectionManager,
      lanServer: lanServer,
      bleServer: bleServer,
      nfcPairingService: nfcPairingService,
      cryptoService: cryptoService,
      secureKeyStore: secureKeyStore,
      peerTrustStore: peerTrustStore,
      secureSessionManager: secureSessionManager,
      transferEngine: transferEngine,
      batteryProvider: batteryProvider,
      transportSelector: transportSelector,
      filePickerService: filePickerService,
      storageService: storageService,
      sessionLifecyclePolicy: sessionLifecyclePolicy,
      fileSharingCoordinator: fileSharingCoordinator,
      capabilityCoordinator: capabilityCoordinator,
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

  /// Current real-time system capabilities (radios, permissions, network).
  SystemCapabilities get systemCapabilities => _systemCapabilities;

  /// Reactive stream of real-time system capabilities.
  Stream<SystemCapabilities> get capabilitiesStream =>
      _capabilitiesController.stream;

  /// Probes real-time system capabilities and notifies listeners.
  Future<SystemCapabilities> refreshCapabilities() async {
    final caps = await platformService.checkCapabilities();
    _systemCapabilities = caps;
    if (!_capabilitiesController.isClosed) {
      _capabilitiesController.add(caps);
    }
    _capabilities = _capabilities.copyWith(
      ble: caps.bluetoothState == RadioState.unsupported
          ? CapabilityStatus.unavailable
          : (caps.bluetoothState == RadioState.enabled ||
                    caps.bluetoothState == RadioState.disabled
                ? CapabilityStatus.supported
                : CapabilityStatus.unknown),
    );
    return caps;
  }

  /// Capability coordinator managing dynamic capability UX and recovery.
  CapabilityCoordinator get capabilityCoordinator {
    if (_capabilityCoordinator == null) {
      throw StateError(
        'CapabilityCoordinator accessed before AppContainer.initialize()',
      );
    }
    return _capabilityCoordinator!;
  }

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

  /// Cryptographic service providing Ed25519, X25519, HKDF, and AES-256-GCM primitives.
  CryptoService get cryptoService {
    if (_cryptoService == null) {
      throw StateError(
        'CryptoService accessed before AppContainer.initialize()',
      );
    }
    return _cryptoService!;
  }

  /// Secure key store for persistent cryptographic key material.
  SecureKeyStore get secureKeyStore {
    if (_secureKeyStore == null) {
      throw StateError(
        'SecureKeyStore accessed before AppContainer.initialize()',
      );
    }
    return _secureKeyStore!;
  }

  /// Peer trust store managing TOFU, SAS, and NFC authentication records.
  PeerTrustStore get trustStore {
    if (_peerTrustStore == null) {
      throw StateError(
        'PeerTrustStore accessed before AppContainer.initialize()',
      );
    }
    return _peerTrustStore!;
  }

  /// Secure session manager orchestrating authenticated Diffie-Hellman key exchanges.
  SecureSessionManager get secureSessionManager {
    if (_secureSessionManager == null) {
      throw StateError(
        'SecureSessionManager accessed before AppContainer.initialize()',
      );
    }
    return _secureSessionManager!;
  }

  /// Local Ed25519 identity keypair.
  CryptoIdentityKeypair? get localKeypair =>
      _secureSessionManager?.localKeypair;

  /// Reactive stream of active, secured communication sessions.
  Stream<SecureSessionImpl> get secureSessionsStream =>
      _secureSessionManager?.secureSessions ?? const Stream.empty();

  /// Currently active secured communication sessions.
  List<SecureSessionImpl> get activeSecureSessions =>
      _secureSessionManager?.activeSessions ?? [];

  /// Retrieves an active secure session by session ID.
  SecureSessionImpl? getSecureSession(String sessionId) =>
      _secureSessionManager?.getSession(sessionId);

  /// Promotes a session's peer to [TrustLevel.sasVerified] after out-of-band SAS code confirmation.
  Future<void> confirmSasVerification(String sessionId) {
    return secureSessionManager.confirmSasVerification(sessionId);
  }

  /// Registers an NFC pairing payload pending incoming/outgoing connection authentication.
  void registerPendingNfcPairing(PairingPayload payload) {
    secureSessionManager.registerPendingNfcPairing(payload);
  }

  /// Initiates dynamic in-band cryptographic rekeying for an active session.
  Future<void> initiateRekey(String sessionId) {
    return secureSessionManager.initiateRekey(sessionId);
  }

  /// Unified transfer engine orchestrating high-performance encrypted data and file transfers.
  TransferEngine get transferEngine {
    if (_transferEngine == null) {
      throw StateError(
        'TransferEngine accessed before AppContainer.initialize()',
      );
    }
    return _transferEngine!;
  }

  /// Incoming single-file offers that need the user's decision. Files from a
  /// batch the user already accepted are handled by the coordinator instead.
  Stream<IncomingTransferRequest> get incomingTransferRequests =>
      _fileSharingCoordinator?.incomingRequests ?? const Stream.empty();

  /// Incoming multi-file offers, answered once for the whole batch.
  Stream<IncomingBatchRequest> get incomingBatchRequests =>
      _fileSharingCoordinator?.incomingBatchRequests ?? const Stream.empty();

  /// Finished transfers kept across restarts (empty before initialize()).
  List<TransferHistoryRecord> get transferHistory =>
      _transferHistory?.records ?? const [];

  /// Removes one entry from the history.
  Future<void> removeFromHistory(String transferId) async {
    await _transferHistory?.remove(transferId);
  }

  /// Empties the history (files already saved are not touched).
  Future<void> clearHistory() async {
    await _transferHistory?.clear();
  }

  /// Timings of the most recent transfers (Diagnostics), if available.
  TransferStatsLog? get transferStatsLog {
    final engine = _transferEngine;
    return engine is TransferEngineImpl ? engine.statsLog : null;
  }

  /// Currently active transfer tasks (both outbound and inbound).
  List<TransferTask> get activeTransfers =>
      _transferEngine?.activeTransfers ?? const [];

  /// Real battery metrics provider.
  BatteryStateProvider get batteryProvider {
    if (_batteryProvider == null) {
      throw StateError(
        'BatteryStateProvider accessed before AppContainer.initialize()',
      );
    }
    return _batteryProvider!;
  }

  /// Smart transport selector evaluating candidates and coordinating fallback.
  TransportSelector get transportSelector {
    if (_transportSelector == null) {
      throw StateError(
        'TransportSelector accessed before AppContainer.initialize()',
      );
    }
    return _transportSelector!;
  }

  /// Platform document picker service (Phase 9).
  FilePickerService get filePickerService {
    if (_filePickerService == null) {
      throw StateError(
        'FilePickerService accessed before AppContainer.initialize()',
      );
    }
    return _filePickerService!;
  }

  /// Platform storage and downloads management service (Phase 9).
  StorageService get storageService {
    if (_storageService == null) {
      throw StateError(
        'StorageService accessed before AppContainer.initialize()',
      );
    }
    return _storageService!;
  }

  /// Policy governing session retention and automatic idle timeout (Phase 9).
  SessionLifecyclePolicy get sessionLifecyclePolicy {
    if (_sessionLifecyclePolicy == null) {
      throw StateError(
        'SessionLifecyclePolicy accessed before AppContainer.initialize()',
      );
    }
    return _sessionLifecyclePolicy!;
  }

  /// End-to-end file sharing coordinator (Phase 9).
  /// QR / link / NFC pairing shared by every out-of-band flow.
  PairingCoordinator get pairingCoordinator {
    if (_pairingCoordinator == null) {
      throw StateError(
        'PairingCoordinator accessed before AppContainer.initialize()',
      );
    }
    return _pairingCoordinator!;
  }

  /// Phone-to-phone Wi-Fi (local-only hotspot) host and joiner.
  LocalHotspotService get hotspotService =>
      _hotspotService ?? const UnsupportedHotspotService();

  FileSharingCoordinator get fileSharingCoordinator {
    if (_fileSharingCoordinator == null) {
      throw StateError(
        'FileSharingCoordinator accessed before AppContainer.initialize()',
      );
    }
    return _fileSharingCoordinator!;
  }

  /// Reactive stream of active and recently completed file transfers.
  Stream<List<TransferTask>> get activeTransfersStream =>
      _fileSharingCoordinator?.activeTransfersStream ?? const Stream.empty();

  /// Central application orchestrator maintaining unified state (Track C: U1–U8).
  AppOrchestrator get orchestrator {
    if (_orchestrator == null) {
      throw StateError(
        'AppOrchestrator accessed before AppContainer.initialize()',
      );
    }
    return _orchestrator!;
  }

  /// Reactive stream of unified application state changes.
  Stream<AppOrchestratorState> get orchestratorStateStream =>
      _orchestrator?.stateStream ?? const Stream.empty();

  /// Current user settings and preferences.
  UserSettings get userSettings => _userSettings;

  /// Reactive stream of user settings changes.
  Stream<UserSettings> get userSettingsStream => _userSettingsController.stream;

  /// Initializes core services, loads/creates device identity, binds discovery coordinator,
  /// starts transport servers, and initializes connection manager and pairing services.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      AppLogger.info('AppContainer', 'Initializing Vayu core container...');

      // 1. Start lifecycle observation
      lifecycleManager.start();

      // 2. Query platform capabilities truthfully
      _capabilities = await platformService.getCapabilities();
      await refreshCapabilities();

      // 2b. Initialize Capability Coordinator (Phase 14)
      _capabilityCoordinator =
          _injectedCapabilityCoordinator ??
          CapabilityCoordinator(
            platformService: platformService,
            lifecycleManager: lifecycleManager,
            initialCapabilities: _systemCapabilities,
            onCapabilitiesChanged: _onCapabilitiesRefreshed,
          );

      // 2c. Load persistent user settings
      _userSettings = await settingsStorage.loadSettings();
      if (!_userSettingsController.isClosed) {
        _userSettingsController.add(_userSettings);
      }

      // 3. Load or mint persistent local device identity
      final loadedIdentity = await identityManager.getOrCreateIdentity();
      if (_userSettings.customDisplayName != null &&
          _userSettings.customDisplayName!.trim().isNotEmpty &&
          _userSettings.customDisplayName != loadedIdentity.displayName) {
        await identityManager.updateDisplayName(
          _userSettings.customDisplayName!,
        );
      }

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
          platformAdapter: Platform.isAndroid && !_isTestEnvironment
              ? AndroidNfcPlatformAdapter()
              : null,
        );
      }

      // 9. Initialize Cryptographic Security Primitives & Secure Session Manager (Phase 6)
      _cryptoService =
          _injectedCryptoService ??
          CryptoService(aead: Platform.isAndroid ? PlatformAeadCipher() : null);
      // Identity keys persist only on Android (Keystore-wrapped). Trust records
      // persist only alongside them: remembering a peer whose own key cannot
      // survive a restart would turn every restart into a key conflict.
      final persistentIdentity = Platform.isAndroid && !_isTestEnvironment;
      _secureKeyStore =
          _injectedSecureKeyStore ??
          (persistentIdentity
              ? const AndroidSecureKeyStore()
              : InMemorySecureKeyStore());
      _peerTrustStore =
          _injectedPeerTrustStore ??
          PeerTrustStore(
            storage: persistentIdentity
                ? FileTrustRecordStorage(
                    File('${AppPaths.androidFilesDir}/peer_trust.json'),
                  )
                : null,
          );
      await _peerTrustStore!.load();

      if (_injectedSecureSessionManager != null) {
        _secureSessionManager = _injectedSecureSessionManager;
      } else {
        _secureSessionManager = SecureSessionManager(
          cryptoService: _cryptoService!,
          trustStore: _peerTrustStore!,
          secureKeyStore: _secureKeyStore!,
          localIdentity: loadedIdentity,
        );
      }

      // Load or mint persistent Ed25519 identity keypair
      await _secureSessionManager!.getOrInitializeLocalKeypair();

      // Wire SecureSessionManager to automatically negotiate encryption for ConnectionManager sessions
      _secureSessionManager!.attachToConnectionManager(_connectionManager!);

      // 10. Initialize Unified Transfer Engine (Phase 7)
      if (_injectedTransferEngine != null) {
        _transferEngine = _injectedTransferEngine;
      } else {
        _transferEngine = TransferEngineImpl(
          localDeviceId: loadedIdentity.idHex,
          secureSessionManager: _secureSessionManager!,
        );
      }

      // 11. Initialize Battery State Provider & Smart Transport Selector (Phase 8)
      _batteryProvider = _injectedBatteryProvider ?? SystemBatteryProvider();
      _transportSelector =
          _injectedTransportSelector ??
          SmartTransportSelectorImpl(
            platformService: platformService,
            batteryProvider: _batteryProvider!,
            connectionManager: _connectionManager!,
            secureSessionManager: _secureSessionManager!,
          );

      // 12. Initialize File Services, Storage Services & File Sharing Coordinator (Phase 9)
      _filePickerService =
          _injectedFilePickerService ?? SystemFilePickerService();
      _storageService = _injectedStorageService ?? SystemStorageService();
      _sessionLifecyclePolicy =
          _injectedSessionLifecyclePolicy ??
          SessionLifecyclePolicy(
            idleTimeout: const Duration(minutes: 3),
            keepAliveAfterTransfer: true,
            onDisconnectSession: (sessionId, reason) async {
              await disconnectSession(sessionId, reason: reason);
            },
          );
      _transferHistory = TransferHistory(
        Platform.isAndroid && !_isTestEnvironment
            ? FileTransferHistoryStorage(
                File('${AppPaths.androidFilesDir}/transfer_history.json'),
              )
            : InMemoryTransferHistoryStorage(),
      );
      await _transferHistory!.load();
      _myCardStore = Platform.isAndroid && !_isTestEnvironment
          ? FileMyCardStore(File('${AppPaths.androidFilesDir}/my_card.json'))
          : InMemoryMyCardStore();
      _myCard = await _myCardStore!.load();
      _fileSharingCoordinator =
          _injectedFileSharingCoordinator ??
          FileSharingCoordinator(
            transferEngine: _transferEngine!,
            transportSelector: _transportSelector!,
            filePickerService: _filePickerService!,
            storageService: _storageService!,
            secureSessionManager: _secureSessionManager!,
            sessionLifecyclePolicy: _sessionLifecyclePolicy!,
            contactDirectory: Platform.isAndroid && !_isTestEnvironment
                ? const ContactPicker().privateDirectory
                : null,
            history: _transferHistory,
            keepAliveController: TransferKeepAliveController(
              keepAlive: Platform.isAndroid
                  ? const AndroidTransferKeepAlive()
                  : const NoopTransferKeepAlive(),
            ),
          );

      _hotspotService = Platform.isAndroid && !_isTestEnvironment
          ? AndroidHotspotService()
          : const UnsupportedHotspotService();
      _pairingCoordinator = PairingCoordinator(
        identity: () => identity,
        lanPort: () => _lanServer?.boundPort,
        localPublicKeyHex: () =>
            _secureSessionManager?.localKeypair?.publicKeyHex,
        supportsBle: () => _capabilities.supportsBle,
        discoveryCoordinator: _discoveryCoordinator!,
        secureSessionManager: _secureSessionManager!,
        transportSelector: _transportSelector!,
        fileSharingCoordinator: _fileSharingCoordinator!,
        hotspot: _hotspotService!,
        activeSessionCount: () =>
            _connectionManager?.activeSessions.length ?? 0,
        sessionChanges: _connectionManager?.activeSessionsStream,
      );

      // 13. Initialize Central Application Orchestrator (Track C: U1–U8)
      _orchestrator = AppOrchestrator(
        capabilityCoordinator: _capabilityCoordinator!,
        discoveryCoordinator: _discoveryCoordinator!,
        connectionManager: _connectionManager!,
        secureSessionManager: _secureSessionManager!,
        fileSharingCoordinator: _fileSharingCoordinator!,
        batteryProvider: _batteryProvider!,
        isBatterySaverActiveEvaluator: (snapshot) {
          return _shouldBatterySaverBeActive(
            _userSettings.batterySaverMode,
            snapshot,
          );
        },
      );

      // Check initial battery saver state and configure discovery throttling
      final initialSnapshot = await _batteryProvider!.getBatterySnapshot();
      final isBatterySaverActive = _shouldBatterySaverBeActive(
        _userSettings.batterySaverMode,
        initialSnapshot,
      );
      _discoveryCoordinator?.setBatterySaver(isBatterySaverActive);

      // 14. Connect lifecycle transitions with discovery state
      lifecycleManager.addListener(_onLifecycleStateChanged);

      _isInitialized = true;
      _initError = null;
      AppLogger.info(
        'AppContainer',
        'Vayu core container initialized successfully for: ${identity?.displayName} (${identity?.idHex.substring(0, 8)}...)',
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
        'App resumed: refreshing platform capabilities',
      );
      refreshCapabilities().ignore();
    }
  }

  /// Reconciles transport state and running discovery when capabilities change.
  Future<void> _onCapabilitiesRefreshed() async {
    final caps =
        _capabilityCoordinator?.rawCapabilities ??
        await platformService.checkCapabilities();
    _systemCapabilities = caps;
    if (!_capabilitiesController.isClosed) {
      _capabilitiesController.add(caps);
    }

    // The GATT server cannot start before Nearby Devices permission is granted,
    // which often happens after launch; retry once BLE becomes usable.
    final bleServer = _bleServer;
    if (bleServer != null && !bleServer.isRunning && caps.canUseBle) {
      try {
        await bleServer.start();
      } catch (e) {
        AppLogger.warning('AppContainer', 'BLE GATT server retry failed: $e');
      }
    }

    if (_discoveryCoordinator != null &&
        _discoveryCoordinator!.status == DiscoveryStatus.active) {
      final canLan = caps.canUseLan || !Platform.isAndroid;
      final canBle = caps.canUseBle;
      if (!canLan && !canBle) {
        AppLogger.warning(
          'AppContainer',
          'All discovery transports lost; stopping discovery',
        );
        await stopDiscoveryAndAdvertising();
      } else {
        final currentActive = _discoveryCoordinator!.activeTransports;
        final needsLan = canLan && !currentActive.contains(TransportType.lan);
        final needsBle = canBle && !currentActive.contains(TransportType.ble);
        final dropLan = !canLan && currentActive.contains(TransportType.lan);
        final dropBle = !canBle && currentActive.contains(TransportType.ble);

        if (needsLan || needsBle || dropLan || dropBle) {
          AppLogger.info(
            'AppContainer',
            'Discovery transports changed; reconciling discovery...',
          );
          try {
            await stopDiscoveryAndAdvertising();
            await startDiscoveryAndAdvertising();
          } catch (e) {
            AppLogger.warning(
              'AppContainer',
              'Failed to reconcile discovery after transport change: $e',
            );
          }
        }
      }
    }
  }

  /// Starts discovery scanning and advertising across all supported transports.
  Future<void> startDiscoveryAndAdvertising() async {
    final id = identity;
    if (id == null) {
      throw StateError('Cannot start discovery before identity is initialized');
    }

    final caps = await refreshCapabilities();

    final bool canLan = caps.canUseLan || !Platform.isAndroid;
    final bool canBle = caps.canUseBle;

    if (!canLan && !canBle) {
      if (caps.isBluetoothOff && !caps.canUseLan) {
        throw StateError(
          'Wi-Fi network is disconnected and Bluetooth is turned off. '
          'Connect to Wi-Fi or turn on Bluetooth to discover nearby devices.',
        );
      }
      if (caps.isNearbyPermissionMissing && !caps.canUseLan) {
        throw StateError(
          'Wi-Fi network is disconnected and Nearby device permission is required for Bluetooth discovery. '
          'Allow nearby device access in settings or connect to Wi-Fi.',
        );
      }
      throw StateError(
        'No viable discovery transports available. '
        'Connect to a local Wi-Fi network or enable Bluetooth with nearby permissions.',
      );
    }

    final supported = <TransportType>{
      if (canLan) TransportType.lan,
      if (canBle) TransportType.ble,
    };

    final serverPort = _lanServer?.boundPort ?? 53531;

    final ad = DeviceAdvertisement(
      deviceId: id.idHex,
      displayName: id.displayName,
      port: serverPort,
      supportedTransports: supported,
      protocolVersion: id.protocolVersion,
    );

    if (canLan && Platform.isAndroid) {
      try {
        await platformService.acquireMulticastLock();
      } catch (e) {
        AppLogger.warning(
          'AppContainer',
          'Failed to acquire multicast lock: $e',
        );
      }
    }

    await discoveryCoordinator.startAdvertising(ad);
    await discoveryCoordinator.startDiscovery();
  }

  /// Stops discovery and advertising.
  Future<void> stopDiscoveryAndAdvertising() async {
    await discoveryCoordinator.stopAdvertising();
    await discoveryCoordinator.stopDiscovery();
    if (Platform.isAndroid) {
      try {
        await platformService.releaseMulticastLock();
      } catch (e) {
        AppLogger.warning(
          'AppContainer',
          'Failed to release multicast lock: $e',
        );
      }
    }
  }

  /// Disposes active resources, servers, discovery timers, and connection sessions.
  void dispose() {
    if (Platform.isAndroid) {
      try {
        platformService.releaseMulticastLock();
      } catch (_) {}
    }
    lifecycleManager.removeListener(_onLifecycleStateChanged);
    _orchestrator?.dispose();
    _orchestrator = null;
    _capabilityCoordinator?.dispose();
    _capabilityCoordinator = null;
    _sessionLifecyclePolicy?.dispose();
    _sessionLifecyclePolicy = null;
    _fileSharingCoordinator?.dispose();
    _fileSharingCoordinator = null;
    _pairingCoordinator = null;
    if (_hotspotService?.isHosting ?? false) {
      _hotspotService?.stop();
    }
    _transferEngine?.dispose();
    _secureSessionManager?.dispose();
    _discoveryCoordinator?.dispose();
    _connectionManager?.dispose();
    _lanServer?.dispose();
    _bleServer?.dispose();
    _nfcPairingService?.dispose();
    lifecycleManager.dispose();
    identityManager.dispose();
    if (!_capabilitiesController.isClosed) {
      _capabilitiesController.close();
    }
    if (!_userSettingsController.isClosed) {
      _userSettingsController.close();
    }
    if (!_myCardController.isClosed) {
      _myCardController.close();
    }
    _isInitialized = false;
  }

  bool _shouldBatterySaverBeActive(
    BatterySaverMode mode,
    BatterySnapshot snapshot,
  ) {
    switch (mode) {
      case BatterySaverMode.on:
        return true;
      case BatterySaverMode.off:
        return false;
      case BatterySaverMode.system:
        return snapshot.isBatterySaverActive == true ||
            snapshot.isCriticalBattery;
    }
  }

  /// Updates user Battery Saver mode and adjusts discovery duty cycles accordingly.
  /// Persists the appearance preference; the app root rebuilds from [userSettingsStream].
  Future<void> setThemePreference(AppThemePreference preference) async {
    _userSettings = _userSettings.copyWith(themePreference: preference);
    await settingsStorage.saveSettings(_userSettings);
    if (!_userSettingsController.isClosed) {
      _userSettingsController.add(_userSettings);
    }
  }

  Future<void> setBatterySaverMode(BatterySaverMode mode) async {
    _userSettings = _userSettings.copyWith(batterySaverMode: mode);
    await settingsStorage.saveSettings(_userSettings);
    if (!_userSettingsController.isClosed) {
      _userSettingsController.add(_userSettings);
    }
    final snapshot =
        await _batteryProvider?.getBatterySnapshot() ??
        BatterySnapshot.unknown();
    final isActive = _shouldBatterySaverBeActive(mode, snapshot);
    _discoveryCoordinator?.setBatterySaver(isActive);
    _orchestrator?.refreshState();
  }

  /// Updates device display name, persists change, and restarts advertising if active.
  Future<void> updateCustomDisplayName(String newName) async {
    await identityManager.updateDisplayName(newName);
    _userSettings = _userSettings.copyWith(customDisplayName: newName);
    await settingsStorage.saveSettings(_userSettings);
    if (!_userSettingsController.isClosed) {
      _userSettingsController.add(_userSettings);
    }
    if (_discoveryCoordinator?.status == DiscoveryStatus.active) {
      await stopDiscoveryAndAdvertising();
      await startDiscoveryAndAdvertising();
    }
  }

  /// The user's own business card, or null before one is created.
  VayuCard? get myCard => _myCard;

  /// Emits whenever the user's card is saved.
  Stream<VayuCard?> get myCardStream => _myCardController.stream;

  /// Saves the user's card on this phone only. The card's name is the
  /// profile name, so the two never disagree.
  Future<void> saveMyCard(VayuCard card) async {
    final store = _myCardStore ?? InMemoryMyCardStore();
    _myCardStore = store;
    await store.save(card);
    _myCard = card;
    if (!_myCardController.isClosed) _myCardController.add(card);
    if (_userSettings.profileName != card.name) {
      await updateProfileName(card.name);
    }
  }

  /// First profile step (onboarding or the home banner): saves the name,
  /// starts the card with it, and, if the phone still has a name Vayu chose,
  /// renames it to "Riya's phone" (first name).
  Future<void> setUpProfile(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final card = _myCard;
    await saveMyCard(
      card == null ? VayuCard(name: trimmed) : card.copyWith(name: trimmed),
    );
    final current = identity?.displayName;
    if (current == null || DeviceNameGenerator.isAutomatic(current)) {
      await updateCustomDisplayName(DeviceNameGenerator.phoneNameFor(trimmed));
    }
  }

  /// Hides the "Set up your profile" banner for good.
  Future<void> dismissProfilePrompt() async {
    _userSettings = _userSettings.copyWith(profilePromptDismissed: true);
    await settingsStorage.saveSettings(_userSettings);
    if (!_userSettingsController.isClosed) {
      _userSettingsController.add(_userSettings);
    }
  }

  /// Saves the person's own name (used on their Vayu card).
  Future<void> updateProfileName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _userSettings = _userSettings.copyWith(profileName: trimmed);
    await settingsStorage.saveSettings(_userSettings);
    if (!_userSettingsController.isClosed) {
      _userSettingsController.add(_userSettings);
    }
  }

  /// Records that onboarding is finished so it is not shown again.
  Future<void> completeOnboarding() async {
    _userSettings = _userSettings.copyWith(
      onboardingVersion: UserSettings.currentOnboardingVersion,
    );
    await settingsStorage.saveSettings(_userSettings);
    if (!_userSettingsController.isClosed) {
      _userSettingsController.add(_userSettings);
    }
  }

  /// Updates custom downloads directory path.
  Future<void> updateCustomDownloadsPath(String path) async {
    _userSettings = _userSettings.copyWith(customDownloadsPath: path);
    await settingsStorage.saveSettings(_userSettings);
    if (!_userSettingsController.isClosed) {
      _userSettingsController.add(_userSettings);
    }
  }

  /// Resolves standard platform storage file without external dependencies.
  static bool get _isTestEnvironment {
    try {
      return Platform.environment.containsKey('FLUTTER_TEST') ||
          WidgetsBinding.instance.runtimeType.toString().contains('Test');
    } catch (_) {
      return false;
    }
  }

  static IdentityStorage _createDefaultFileStorage() {
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST') ||
          WidgetsBinding.instance.runtimeType.toString().contains('Test')) {
        return InMemoryIdentityStorage();
      }
      File file;
      if (Platform.isAndroid) {
        final dir = Directory(AppPaths.androidFilesDir);
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

  /// Resolves standard platform settings file without external dependencies.
  static SettingsStorage _createDefaultSettingsStorage() {
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST') ||
          WidgetsBinding.instance.runtimeType.toString().contains('Test')) {
        return InMemorySettingsStorage();
      }
      File file;
      if (Platform.isAndroid) {
        final dir = Directory(AppPaths.androidFilesDir);
        file = File('${dir.path}/user_settings.json');
      } else if (Platform.isWindows) {
        final appData =
            Platform.environment['APPDATA'] ??
            Platform.environment['LOCALAPPDATA'];
        if (appData != null) {
          file = File('$appData/${AppConstants.appName}/user_settings.json');
        } else {
          file = File(
            '${Directory.systemTemp.path}/${AppConstants.applicationId}/user_settings.json',
          );
        }
      } else {
        file = File(
          '${Directory.systemTemp.path}/${AppConstants.applicationId}/user_settings.json',
        );
      }
      return FileSettingsStorage(file);
    } catch (_) {
      return InMemorySettingsStorage();
    }
  }
}
