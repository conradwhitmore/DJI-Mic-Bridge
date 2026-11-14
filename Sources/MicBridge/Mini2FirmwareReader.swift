import CoreBluetooth
import Foundation
import Mini2Protocol

/// Read-only preflight. Owns BLE until disconnect is confirmed; never opens SPP itself.
final class Mini2FirmwareReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private(set) var busy = false
    var changed: ((Bool, String) -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var notifier: CBCharacteristic?
    private var parser = Mini2DUMLParser()
    private var request: Mini2Request?
    private var result: Mini2FirmwareIdentity?
    private var completion: ((Mini2FirmwareIdentity?) -> Void)?
    private var address = ""
    private var deadline: TimeInterval = 0
    private var closing = false
    private var timer: Timer?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func read(address: String, completion: @escaping (Mini2FirmwareIdentity?) -> Void) {
        guard !busy else { return }
        self.address = address; self.completion = completion
        busy = true; closing = false; result = nil; request = nil
        parser = Mini2DUMLParser(); deadline = now + 12
        changed?(true, "首次连接，正在读取固件版本…")
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Cancels the continuation as well as BLE, including during app termination.
    func cancel() { completion = nil; stopReading() }

    private func tick() {
        guard busy else { return }
        if closing {
            if peripheral == nil || peripheral?.state == .disconnected { finish() }
            else if now >= deadline {
                changed?(true, "正在关闭固件查询的 BLE 连接…")
                deadline = now + 5
                if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            }
        } else if now >= deadline { stopReading() }
    }

    private func stopReading() {
        guard busy, !closing else { return }
        closing = true; request = nil; central?.stopScan(); deadline = now + 3
        if let peripheral, peripheral.state != .disconnected {
            changed?(true, "固件查询结束，正在连接 SPP…")
            central?.cancelPeripheralConnection(peripheral)
        } else { finish() }
    }

    private func finish() {
        guard busy else { return }
        let done = completion, value = result
        completion = nil; timer?.invalidate(); timer = nil
        central?.stopScan(); peripheral?.delegate = nil; peripheral = nil
        writer = nil; notifier = nil; request = nil
        central?.delegate = nil; central = nil
        busy = false; closing = false
        changed?(false, "")
        done?(value)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, busy else { return }
        if central.state == .poweredOn, !closing, peripheral == nil {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        } else if [.poweredOff, .unauthorized, .unsupported].contains(central.state) {
            // No active radio connection remains in these states.
            finish()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, busy, !closing, peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard Mini2FirmwareIdentity.matches(advertisedName: name, address: address) else { return }
        central.stopScan(); peripheral = p; p.delegate = self; central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral, !closing else { central.cancelPeripheralConnection(p); return }
        p.discoverServices([CBUUID(string: "FFF0")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }; finish()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }; finish()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral, !closing else { return }
        guard error == nil, let service = p.services?.first(where: { $0.uuid == CBUUID(string: "FFF0") }) else {
            stopReading(); return
        }
        p.discoverCharacteristics([CBUUID(string: "FFF3"), CBUUID(string: "FFF4")], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral, !closing else { return }
        guard error == nil else { stopReading(); return }
        writer = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF3") && !$0.properties.intersection([.write, .writeWithoutResponse]).isEmpty }
        notifier = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF4") && !$0.properties.intersection([.notify, .indicate]).isEmpty }
        guard writer != nil, let notifier else { stopReading(); return }
        p.setNotifyValue(true, for: notifier)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c === notifier, !closing, request == nil else { return }
        guard error == nil, c.isNotifying, let writer else { stopReading(); return }
        let query = Mini2Request(.version, sequence: UInt16.random(in: 1...UInt16.max))
        let type: CBCharacteristicWriteType = writer.properties.contains(.write) ? .withResponse : .withoutResponse
        guard query.packet.count <= p.maximumWriteValueLength(for: type),
              type == .withResponse || p.canSendWriteWithoutResponse else { stopReading(); return }
        request = query
        p.writeValue(Data(query.packet), for: writer, type: type)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        // This TX can return ATT Unlikely Error and still deliver the valid DUML response.
        // Keep waiting for a matching, CRC-validated reply until the overall deadline.
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, c === notifier, !closing, error == nil, let data = c.value else { return }
        for frame in parser.feed(data) {
            guard let request, request.matches(frame), let payload = try? request.validate(frame),
                  let identity = Mini2FirmwareIdentity(payload: payload, peripheralID: p.identifier) else { continue }
            result = identity; stopReading(); return
        }
    }
}
