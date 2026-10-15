import Flutter
import CoreBluetooth
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let methodChannelName = "com.rouddy.bluetooth_communicator/bluetooth_control"
  private let eventChannelName = "com.rouddy.bluetooth_communicator/bluetooth_events"
  private let bleManager = IOSBleBackgroundManager()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // With the UIScene lifecycle the window (and its FlutterViewController) doesn't
  // exist yet in didFinishLaunchingWithOptions, so the channels are registered on
  // the implicit engine's messenger instead.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerBleChannels(messenger: engineBridge.applicationRegistrar.messenger())
  }

  private func registerBleChannels(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "NO_APP", message: "App unavailable", details: nil))
        return
      }
      switch call.method {
      case "initialize":
        self.bleManager.restoreState()
        result(nil)
      case "setAdvertisingEnabled":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        self.bleManager.setAdvertisingEnabled(enabled)
        result(nil)
      case "setCentralEnabled":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        self.bleManager.setCentralEnabled(enabled)
        result(nil)
      case "scanNow":
        self.bleManager.scanNow()
        result(nil)
      case "connectDevice":
        let args = call.arguments as? [String: Any]
        let deviceId = args?["deviceId"] as? String
        self.bleManager.connectDevice(deviceId)
        result(nil)
      case "disconnectDevice":
        let args = call.arguments as? [String: Any]
        self.bleManager.disconnectDevice(args?["deviceId"] as? String)
        result(nil)
      case "sendMessage":
        let args = call.arguments as? [String: Any]
        let deviceId = args?["deviceId"] as? String
        let message = args?["message"] as? String
        let messageId = args?["messageId"] as? String
        self.bleManager.sendMessage(deviceId: deviceId, message: message, messageId: messageId)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(bleManager)
  }
}

final class IOSBleBackgroundManager: NSObject, FlutterStreamHandler {
  private let serviceUUID = CBUUID(string: "1F9ED31D-B738-4D4C-A6D8-86DBF0F9C001")
  private let messageCharacteristicUUID = CBUUID(string: "DB912050-2E4E-4C4E-A543-E89121E57595")
  private let prefs = UserDefaults.standard
  private let pendingMessagesKey = "pending_messages"

  private lazy var centralManager: CBCentralManager = {
    CBCentralManager(
      delegate: self,
      queue: nil,
      options: [CBCentralManagerOptionRestoreIdentifierKey: "ble.central.restore"]
    )
  }()
  private lazy var peripheralManager: CBPeripheralManager = {
    CBPeripheralManager(
      delegate: self,
      queue: nil,
      options: [CBPeripheralManagerOptionRestoreIdentifierKey: "ble.peripheral.restore"]
    )
  }()

  private var eventSink: FlutterEventSink?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var writableCharacteristics: [UUID: CBCharacteristic] = [:]
  // Peripherals the user disconnected on purpose; didDisconnectPeripheral must not
  // reconnect them until they're connected again explicitly.
  private var forgottenPeripherals: Set<UUID> = []
  private var connectedPeripheralIds: Set<UUID> = []
  // Links that were up when Bluetooth powered off; reconnected once it's back on.
  private var peripheralsToReconnect: Set<UUID> = []
  // connectDevice calls made before the central manager was powered on (e.g. Dart
  // reconnecting saved devices right after launch); issued once it is.
  private var pendingConnectIds: Set<UUID> = []
  // Subscription retries per peripheral while pairing is in progress.
  private var subscribeAttempts: [UUID: Int] = [:]
  private var advertisingEnabled = false
  private var centralEnabled = false

  // Peripheral role: the message service that remote centrals write to and subscribe
  // to for our replies (mirrors the Android GATT server).
  private var messageCharacteristic: CBMutableCharacteristic?
  private var serviceAdded = false
  private var addingService = false
  private var subscribedCentrals: [UUID: CBCentral] = [:]
  private var pendingNotifications: [(data: Data, central: CBCentral, messageId: String?)] = []
  // Message ids of writes with response, per peripheral, in the order CoreBluetooth
  // reports them back through didWriteValueFor.
  private var pendingWrites: [UUID: [String?]] = [:]

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    emit(type: "status", payload: ["status": "ios-ready"])
    // Messages that arrived before Dart listened (e.g. the system relaunched the app in
    // the background for a BLE event through state restoration).
    let pending = prefs.array(forKey: pendingMessagesKey) as? [[String: Any]] ?? []
    prefs.removeObject(forKey: pendingMessagesKey)
    pending.forEach { events($0) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func restoreState() {
    advertisingEnabled = prefs.bool(forKey: "pref_ios_advertising")
    centralEnabled = prefs.bool(forKey: "pref_ios_central")
    if advertisingEnabled {
      startAdvertisingIfPossible()
    }
    if centralEnabled {
      startScanningIfPossible()
    }
  }

  func setAdvertisingEnabled(_ enabled: Bool) {
    advertisingEnabled = enabled
    prefs.set(enabled, forKey: "pref_ios_advertising")
    if enabled {
      startAdvertisingIfPossible()
    } else {
      peripheralManager.stopAdvertising()
      removeMessageService()
      emit(type: "status", payload: ["status": "advertising-off"])
    }
  }

  func setCentralEnabled(_ enabled: Bool) {
    centralEnabled = enabled
    prefs.set(enabled, forKey: "pref_ios_central")
    if enabled {
      startScanningIfPossible()
    } else {
      centralManager.stopScan()
      emit(type: "status", payload: ["status": "scan-off"])
    }
  }

  func scanNow() {
    guard centralEnabled else { return }
    startScanningIfPossible()
  }

  func connectDevice(_ deviceId: String?) {
    guard let deviceId, let uuid = UUID(uuidString: deviceId) else { return }
    forgottenPeripherals.remove(uuid)
    guard centralManager.state == .poweredOn else {
      pendingConnectIds.insert(uuid)
      return
    }
    // After a relaunch a saved device isn't in `peripherals` until it's scanned
    // again, but CoreBluetooth can still hand it out by identifier.
    guard let peripheral = peripherals[uuid]
      ?? centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
    else {
      emit(type: "error", payload: ["message": "Unknown device \(deviceId)"])
      return
    }
    peripherals[uuid] = peripheral
    guard peripheral.state == .disconnected else { return }
    centralManager.connect(peripheral, options: nil)
  }

  func disconnectDevice(_ deviceId: String?) {
    guard let deviceId, let uuid = UUID(uuidString: deviceId) else { return }
    if let peripheral = peripherals[uuid] {
      forgottenPeripherals.insert(uuid)
      writableCharacteristics.removeValue(forKey: uuid)
      centralManager.cancelPeripheralConnection(peripheral)
    }
    // CoreBluetooth can't drop a central connected to our service: it stays
    // subscribed until the remote side disconnects.
  }

  func sendMessage(deviceId: String?, message: String?, messageId: String?) {
    guard let deviceId, let message, let uuid = UUID(uuidString: deviceId) else {
      reportSend(deviceId: deviceId ?? "", messageId: messageId, error: "No writable BLE connection")
      return
    }
    let data = Data(message.utf8)
    guard let peripheral = peripherals[uuid], let characteristic = writableCharacteristics[uuid] else {
      // Not our GATT client link; the peer may be a central subscribed to our service.
      notifyCentral(uuid, data: data, messageId: messageId)
      return
    }
    if characteristic.properties.contains(.write) {
      let maxLength = peripheral.maximumWriteValueLength(for: .withResponse)
      if data.count > maxLength {
        reportSend(deviceId: deviceId, messageId: messageId, error: "Message too long (\(data.count)/\(maxLength) bytes)")
        return
      }
      // CoreBluetooth queues writes itself and answers each in order.
      pendingWrites[uuid, default: []].append(messageId)
      peripheral.writeValue(data, for: characteristic, type: .withResponse)
    } else if characteristic.properties.contains(.writeWithoutResponse) {
      peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
      reportSend(deviceId: deviceId, messageId: messageId, error: nil)
    } else {
      reportSend(deviceId: deviceId, messageId: messageId, error: "Characteristic not writable")
    }
  }

  private func notifyCentral(_ id: UUID, data: Data, messageId: String?) {
    guard let central = subscribedCentrals[id], let characteristic = messageCharacteristic else {
      reportSend(deviceId: id.uuidString, messageId: messageId, error: "No writable BLE connection for \(id.uuidString)")
      return
    }
    // A notification can't be split, so it must fit in a single ATT packet.
    let maxLength = central.maximumUpdateValueLength
    if data.count > maxLength {
      reportSend(deviceId: id.uuidString, messageId: messageId, error: "Message too long (\(data.count)/\(maxLength) bytes)")
      return
    }
    // Keep the order: once something is queued, everything after it queues too.
    if pendingNotifications.isEmpty &&
      peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: [central]) {
      reportSend(deviceId: id.uuidString, messageId: messageId, error: nil)
    } else {
      // The transmit queue is full; peripheralManagerIsReady(toUpdateSubscribers:) retries.
      pendingNotifications.append((data: data, central: central, messageId: messageId))
    }
  }

  /// Reports a send's outcome (`error == nil` means sent). Without a message id only
  /// failures are reported, as a generic error.
  private func reportSend(deviceId: String, messageId: String?, error: String?) {
    guard let messageId else {
      if let error {
        emit(type: "error", payload: ["message": error])
      }
      return
    }
    if let error {
      emit(type: "messageFailed", payload: ["deviceId": deviceId, "messageId": messageId, "error": error])
    } else {
      emit(type: "messageSent", payload: ["deviceId": deviceId, "messageId": messageId])
    }
  }

  private func failPendingWrites(_ id: UUID, error: String) {
    let ids = pendingWrites.removeValue(forKey: id) ?? []
    ids.forEach { reportSend(deviceId: id.uuidString, messageId: $0, error: error) }
  }

  private func failPendingNotifications(where shouldFail: (CBCentral) -> Bool, error: String) {
    let failed = pendingNotifications.filter { shouldFail($0.central) }
    pendingNotifications.removeAll { shouldFail($0.central) }
    failed.forEach {
      reportSend(deviceId: $0.central.identifier.uuidString, messageId: $0.messageId, error: error)
    }
  }

  private func startAdvertisingIfPossible() {
    guard peripheralManager.state == .poweredOn else { return }
    guard serviceAdded else {
      // Advertising starts from didAdd once the service is published, so a central
      // that connects right away finds the characteristic.
      addMessageServiceIfNeeded()
      return
    }
    guard !peripheralManager.isAdvertising else { return }
    peripheralManager.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
      CBAdvertisementDataLocalNameKey: UIDevice.current.name
    ])
  }

  private func addMessageServiceIfNeeded() {
    guard !serviceAdded, !addingService else { return }
    // Like the Android server: writes and subscriptions need an encrypted (bonded)
    // link, so an unbonded central is asked to pair first.
    let characteristic = CBMutableCharacteristic(
      type: messageCharacteristicUUID,
      properties: [.write, .writeWithoutResponse, .notifyEncryptionRequired],
      value: nil,
      permissions: [.writeEncryptionRequired]
    )
    let service = CBMutableService(type: serviceUUID, primary: true)
    service.characteristics = [characteristic]
    messageCharacteristic = characteristic
    addingService = true
    peripheralManager.add(service)
  }

  private func removeMessageService() {
    peripheralManager.removeAllServices()
    resetPeripheralRole()
  }

  /// Forgets the published service and its subscribers, e.g. after advertising is
  /// turned off or Bluetooth powers down (which drops published services).
  private func resetPeripheralRole() {
    serviceAdded = false
    addingService = false
    messageCharacteristic = nil
    failPendingNotifications(where: { _ in true }, error: "GATT service removed")
    let centrals = Array(subscribedCentrals.keys)
    subscribedCentrals.removeAll()
    centrals.forEach { emitDisconnectedIfUnlinked($0) }
  }

  // A peer can be linked twice (we're its central and it's ours), so it only counts
  // as disconnected once neither link is left.
  private func emitDisconnectedIfUnlinked(_ id: UUID) {
    if subscribedCentrals[id] != nil || peripherals[id]?.state == .connected {
      return
    }
    emit(type: "disconnected", payload: ["deviceId": id.uuidString])
  }

  private func startScanningIfPossible() {
    guard centralManager.state == .poweredOn else { return }
    centralManager.scanForPeripherals(withServices: [serviceUUID], options: [
      CBCentralManagerScanOptionAllowDuplicatesKey: false
    ])
    emit(type: "status", payload: ["status": "scanning"])
  }

  private func emit(type: String, payload: [String: Any]) {
    var event: [String: Any] = ["type": type]
    payload.forEach { event[$0.key] = $0.value }
    if let eventSink {
      eventSink(event)
    } else if type == "message" {
      // Other events describe state that's replayed on the next initialize; a message
      // is lost unless it's kept until Dart listens.
      var pending = prefs.array(forKey: pendingMessagesKey) as? [[String: Any]] ?? []
      pending.append(event)
      prefs.set(Array(pending.suffix(500)), forKey: pendingMessagesKey)
    }
  }

  private var nowMillis: Int { Int(Date().timeIntervalSince1970 * 1000) }
}

extension IOSBleBackgroundManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      if centralEnabled {
        startScanningIfPossible()
        // Connections don't survive a power cycle; bring back the ones that were up.
        peripheralsToReconnect
          .compactMap { peripherals[$0] }
          .forEach { central.connect($0, options: nil) }
      }
      peripheralsToReconnect.removeAll()
      let pending = pendingConnectIds
      pendingConnectIds.removeAll()
      pending.forEach { connectDevice($0.uuidString) }
      // Links restored by state restoration lost their characteristic reference
      // with the old process; look it up again.
      peripherals.values
        .filter { $0.state == .connected && writableCharacteristics[$0.identifier] == nil }
        .forEach { $0.discoverServices([serviceUUID]) }
    case .poweredOff:
      // CoreBluetooth drops every link without calling didDisconnectPeripheral.
      peripheralsToReconnect = connectedPeripheralIds.subtracting(forgottenPeripherals)
      let dropped = connectedPeripheralIds
      connectedPeripheralIds.removeAll()
      writableCharacteristics.removeAll()
      Array(pendingWrites.keys).forEach { failPendingWrites($0, error: "Bluetooth turned off") }
      dropped.forEach { emitDisconnectedIfUnlinked($0) }
      emit(type: "status", payload: ["status": "bluetooth-off"])
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    willRestoreState dict: [String: Any]
  ) {
    // Commands have to wait for poweredOn; centralManagerDidUpdateState resumes these.
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    for peripheral in restored {
      peripheral.delegate = self
      peripherals[peripheral.identifier] = peripheral
      if peripheral.state == .connected {
        connectedPeripheralIds.insert(peripheral.identifier)
      }
    }
    emit(type: "status", payload: ["status": "central-restored"])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    emit(type: "error", payload: [
      "message": "Connection to \(peripheral.identifier.uuidString) failed: \(error?.localizedDescription ?? "unknown error")"
    ])
    emitDisconnectedIfUnlinked(peripheral.identifier)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    peripherals[peripheral.identifier] = peripheral
    // Android puts its name in the scan response; peripheral.name is only the cached
    // GAP name, which a peer that was never connected doesn't have yet.
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
    emit(type: "discovered", payload: [
      "deviceId": peripheral.identifier.uuidString,
      "name": name
    ])
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    connectedPeripheralIds.insert(peripheral.identifier)
    subscribeAttempts.removeValue(forKey: peripheral.identifier)
    peripheral.delegate = self
    // `connected` is reported once the subscription succeeds: until then (service
    // discovery, pairing) messages can't be exchanged yet.
    peripheral.discoverServices([serviceUUID])
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    writableCharacteristics.removeValue(forKey: peripheral.identifier)
    connectedPeripheralIds.remove(peripheral.identifier)
    failPendingWrites(peripheral.identifier, error: "Disconnected")
    emitDisconnectedIfUnlinked(peripheral.identifier)
    if centralEnabled && !forgottenPeripherals.contains(peripheral.identifier) {
      central.connect(peripheral, options: nil)
    }
  }
}

extension IOSBleBackgroundManager: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      if advertisingEnabled {
        startAdvertisingIfPossible()
      }
    case .poweredOff:
      resetPeripheralRole()
      emit(type: "status", payload: ["status": "bluetooth-off"])
    default:
      break
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
    let characteristic = services
      .first { $0.uuid == serviceUUID }?
      .characteristics?
      .first { $0.uuid == messageCharacteristicUUID } as? CBMutableCharacteristic
    if let characteristic {
      messageCharacteristic = characteristic
      serviceAdded = true
      characteristic.subscribedCentrals?.forEach { subscribedCentrals[$0.identifier] = $0 }
    }
    emit(type: "status", payload: ["status": "peripheral-restored"])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    addingService = false
    if let error {
      messageCharacteristic = nil
      emit(type: "error", payload: ["message": "Failed to add GATT service: \(error.localizedDescription)"])
      return
    }
    serviceAdded = true
    if advertisingEnabled {
      startAdvertisingIfPossible()
    }
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error {
      emit(type: "error", payload: ["message": "Advertising failed: \(error.localizedDescription)"])
      return
    }
    emit(type: "status", payload: ["status": "advertising"])
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didSubscribeTo characteristic: CBCharacteristic
  ) {
    guard characteristic.uuid == messageCharacteristicUUID else { return }
    if subscribedCentrals.updateValue(central, forKey: central.identifier) == nil {
      emit(type: "connected", payload: ["deviceId": central.identifier.uuidString])
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    central: CBCentral,
    didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    guard characteristic.uuid == messageCharacteristicUUID else { return }
    if subscribedCentrals.removeValue(forKey: central.identifier) != nil {
      failPendingNotifications(where: { $0.identifier == central.identifier }, error: "Unsubscribed")
      emitDisconnectedIfUnlinked(central.identifier)
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    guard requests.allSatisfy({ $0.characteristic.uuid == messageCharacteristicUUID }) else {
      peripheral.respond(to: first, withResult: .requestNotSupported)
      return
    }
    // A long (queued) write arrives as several requests in offset order, and
    // CoreBluetooth expects one response for the whole batch.
    var messages: [UUID: Data] = [:]
    for request in requests {
      messages[request.central.identifier, default: Data()].append(request.value ?? Data())
    }
    peripheral.respond(to: first, withResult: .success)
    for (centralId, data) in messages {
      guard let message = String(data: data, encoding: .utf8) else { continue }
      emit(type: "message", payload: [
        "deviceId": centralId.uuidString, "message": message, "receivedAt": nowMillis
      ])
    }
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard let characteristic = messageCharacteristic else {
      failPendingNotifications(where: { _ in true }, error: "GATT service removed")
      return
    }
    while let next = pendingNotifications.first {
      guard peripheral.updateValue(next.data, for: characteristic, onSubscribedCentrals: [next.central]) else {
        return
      }
      pendingNotifications.removeFirst()
      reportSend(deviceId: next.central.identifier.uuidString, messageId: next.messageId, error: nil)
    }
  }
}

extension IOSBleBackgroundManager: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil else { return }
    peripheral.services?.forEach { service in
      if service.uuid == serviceUUID {
        peripheral.discoverCharacteristics([messageCharacteristicUUID], for: service)
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil else { return }
    let characteristic = service.characteristics?.first { $0.uuid == messageCharacteristicUUID }
    if let characteristic {
      writableCharacteristics[peripheral.identifier] = characteristic
      peripheral.setNotifyValue(true, for: characteristic)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == messageCharacteristicUUID else { return }
    let id = peripheral.identifier
    guard let error else {
      subscribeAttempts.removeValue(forKey: id)
      emit(type: "connected", payload: ["deviceId": id.uuidString])
      return
    }
    // The peer requires an encrypted link. The first attempt makes iOS start pairing
    // but fails itself, and CoreBluetooth doesn't retry it, so retry until pairing is
    // done (the system dialog times out after about 30 s).
    let code = (error as? CBATTError)?.code
    let attempts = subscribeAttempts[id, default: 0] + 1
    if code == .insufficientAuthentication || code == .insufficientEncryption, attempts <= 30 {
      subscribeAttempts[id] = attempts
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, peripheral.state == .connected,
          let current = self.writableCharacteristics[id]
        else { return }
        peripheral.setNotifyValue(true, for: current)
      }
      return
    }
    subscribeAttempts.removeValue(forKey: id)
    emit(type: "error", payload: [
      "message": "Subscribing to \(id.uuidString) failed: \(error.localizedDescription)"
    ])
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == messageCharacteristicUUID,
      var ids = pendingWrites[peripheral.identifier], !ids.isEmpty
    else { return }
    let messageId = ids.removeFirst()
    pendingWrites[peripheral.identifier] = ids
    reportSend(deviceId: peripheral.identifier.uuidString, messageId: messageId, error: error?.localizedDescription)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard
      error == nil,
      characteristic.uuid == messageCharacteristicUUID,
      let value = characteristic.value,
      let message = String(data: value, encoding: .utf8)
    else { return }
    emit(type: "message", payload: [
      "deviceId": peripheral.identifier.uuidString,
      "message": message,
      "receivedAt": nowMillis
    ])
  }
}
