//
//  BluetoothLyricsTransport.swift
//  Amperfy
//

import CoreBluetooth
import Foundation

// MARK: - BluetoothLyricsConnectionStatus

enum BluetoothLyricsConnectionStatus: Equatable {
  case disabled
  case bluetoothUnavailable
  case scanning
  case connecting(String)
  case connected(String)

  var description: String {
    switch self {
    case .disabled: return "Disabled"
    case .bluetoothUnavailable: return "Bluetooth unavailable"
    case .scanning: return "Searching for display…"
    case let .connecting(name): return "Connecting to \(name)…"
    case let .connected(name): return "Connected to \(name)"
    }
  }
}

// MARK: - BluetoothLyricsTransport

@MainActor
final class BluetoothLyricsTransport: NSObject, ObservableObject {
  static let shared = BluetoothLyricsTransport()

  static let serviceUUID = CBUUID(string: "7A8B0001-6E12-4A87-9F12-123456789ABC")
  static let writeCharacteristicUUID = CBUUID(
    string: "7A8B0002-6E12-4A87-9F12-123456789ABC"
  )

  @Published private(set) var status: BluetoothLyricsConnectionStatus = .disabled

  private var centralManager: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var writeCharacteristic: CBCharacteristic?
  private var isEnabled = false
  private var reconnectWorkItem: DispatchWorkItem?

  private var activeChunks: [Data] = []
  private var pendingLatestFrame: Data?
  private var latestFrame: Data?
  private var isWriteInFlight = false

  override private init() {
    super.init()
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else {
      if enabled { beginScanningIfPossible() }
      return
    }

    isEnabled = enabled
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil

    if enabled {
      ensureCentralManager()
      beginScanningIfPossible()
    } else {
      centralManager?.stopScan()
      if let centralManager, let peripheral {
        centralManager.cancelPeripheralConnection(peripheral)
      }
      resetConnection(keepLatestFrame: false)
      status = .disabled
    }
  }

  private func ensureCentralManager() {
    guard centralManager == nil else { return }
    centralManager = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [CBCentralManagerOptionRestoreIdentifierKey: "AmperfyLyricsCentral"]
    )
  }

  func send(_ message: ExternalLyricsMessage) {
    guard isEnabled else { return }
    do {
      var data = try JSONEncoder().encode(message)
      data.append(0x0A)
      latestFrame = data
      enqueueLatestFrame(data)
    } catch {
      // The message only contains JSON-native values, so encoding failure is not recoverable.
    }
  }

  private func beginScanningIfPossible() {
    guard isEnabled else { return }
    guard let centralManager, centralManager.state == .poweredOn else {
      status = .bluetoothUnavailable
      return
    }
    guard peripheral == nil else { return }

    status = .scanning
    centralManager.scanForPeripherals(
      withServices: [Self.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }

  private func connect(_ discoveredPeripheral: CBPeripheral) {
    guard let centralManager else { return }
    centralManager.stopScan()
    peripheral = discoveredPeripheral
    discoveredPeripheral.delegate = self
    status = .connecting(discoveredPeripheral.name ?? "Lyrics display")
    centralManager.connect(discoveredPeripheral)
  }

  private func resetConnection(keepLatestFrame: Bool = true) {
    peripheral?.delegate = nil
    peripheral = nil
    writeCharacteristic = nil
    activeChunks.removeAll()
    pendingLatestFrame = nil
    isWriteInFlight = false
    if !keepLatestFrame { latestFrame = nil }
  }

  private func scheduleReconnect() {
    guard isEnabled else { return }
    reconnectWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor in self?.beginScanningIfPossible() }
    }
    reconnectWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
  }

  private func enqueueLatestFrame(_ frame: Data) {
    guard writeCharacteristic != nil else { return }
    if isWriteInFlight || !activeChunks.isEmpty {
      pendingLatestFrame = frame
      return
    }
    activeChunks = makeChunks(from: frame)
    writeNextChunk()
  }

  private func makeChunks(from frame: Data) -> [Data] {
    guard let peripheral else { return [] }
    let maximumLength = max(
      peripheral.maximumWriteValueLength(for: .withResponse),
      20
    )
    return stride(from: 0, to: frame.count, by: maximumLength).map { offset in
      frame.subdata(in: offset..<min(offset + maximumLength, frame.count))
    }
  }

  private func writeNextChunk() {
    guard !isWriteInFlight,
          let peripheral,
          let writeCharacteristic
    else { return }

    if activeChunks.isEmpty {
      if let pendingLatestFrame {
        self.pendingLatestFrame = nil
        activeChunks = makeChunks(from: pendingLatestFrame)
      } else {
        return
      }
    }

    guard !activeChunks.isEmpty else { return }
    let chunk = activeChunks.removeFirst()
    isWriteInFlight = true
    peripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
  }
}

// MARK: CBCentralManagerDelegate

extension BluetoothLyricsTransport: @preconcurrency CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn {
      beginScanningIfPossible()
    } else if isEnabled {
      resetConnection()
      status = .bluetoothUnavailable
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard isEnabled, self.peripheral == nil else { return }
    connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Self.serviceUUID])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    resetConnection()
    scheduleReconnect()
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    resetConnection()
    scheduleReconnect()
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard isEnabled,
          let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
          let restoredPeripheral = peripherals.first
    else { return }
    peripheral = restoredPeripheral
    restoredPeripheral.delegate = self
    status = .connecting(restoredPeripheral.name ?? "Lyrics display")
    if restoredPeripheral.state == .connected {
      restoredPeripheral.discoverServices([Self.serviceUUID])
    } else {
      central.connect(restoredPeripheral)
    }
  }
}

// MARK: CBPeripheralDelegate

extension BluetoothLyricsTransport: @preconcurrency CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil,
          let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
    else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics([Self.writeCharacteristicUUID], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil,
          let characteristic = service.characteristics?
          .first(where: { $0.uuid == Self.writeCharacteristicUUID })
    else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }

    writeCharacteristic = characteristic
    status = .connected(peripheral.name ?? "Lyrics display")
    if let latestFrame { enqueueLatestFrame(latestFrame) }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == Self.writeCharacteristicUUID else { return }
    isWriteInFlight = false
    if error != nil {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    writeNextChunk()
  }
}
