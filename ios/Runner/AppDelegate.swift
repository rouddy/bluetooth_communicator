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
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: controller.binaryMessenger
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
      case "sendMessage":
        let args = call.arguments as? [String: Any]
        let deviceId = args?["deviceId"] as? String
        let message = args?["message"] as? String
        self.bleManager.sendMessage(deviceId: deviceId, message: message)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    eventChannel.setStreamHandler(bleManager)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

final class IOSBleBackgroundManager: NSObject, FlutterStreamHandler {
  private let serviceUUID = CBUUID(string: "1F9ED31D-B738-4D4C-A6D8-86DBF0F9C001")
  private let prefs = UserDefaults.standard

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
  private var advertisingEnabled = false
  private var centralEnabled = false

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    emit(type: "status", payload: ["status": "ios-ready"])
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
    guard
      let deviceId,
      let uuid = UUID(uuidString: deviceId),
      let peripheral = peripherals[uuid]
    else { return }
    centralManager.connect(peripheral, options: nil)
  }

  func sendMessage(deviceId: String?, message: String?) {
    guard let deviceId, let message else { return }
    emit(type: "message", payload: ["deviceId": deviceId, "message": "echo:\(message)"])
  }

  private func startAdvertisingIfPossible() {
    guard peripheralManager.state == .poweredOn else { return }
    peripheralManager.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
      CBAdvertisementDataLocalNameKey: UIDevice.current.name
    ])
    emit(type: "status", payload: ["status": "advertising"])
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
    eventSink?(event)
  }
}

extension IOSBleBackgroundManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      if centralEnabled {
        startScanningIfPossible()
      }
    case .poweredOff:
      emit(type: "status", payload: ["status": "bluetooth-off"])
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    willRestoreState dict: [String: Any]
  ) {
    emit(type: "status", payload: ["status": "central-restored"])
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    peripherals[peripheral.identifier] = peripheral
    emit(type: "discovered", payload: [
      "deviceId": peripheral.identifier.uuidString,
      "name": peripheral.name ?? ""
    ])
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    emit(type: "connected", payload: ["deviceId": peripheral.identifier.uuidString])
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    emit(type: "disconnected", payload: ["deviceId": peripheral.identifier.uuidString])
    if centralEnabled {
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
      emit(type: "status", payload: ["status": "bluetooth-off"])
    default:
      break
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    emit(type: "status", payload: ["status": "peripheral-restored"])
  }
}
