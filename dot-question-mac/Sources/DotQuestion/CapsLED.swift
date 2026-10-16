import Foundation
import Combine
#if canImport(CoreHID)
import CoreHID
#endif

/// Optional physical LED output only. Never posts keyboard events or changes Caps Lock state.
/// CoreHID is SDK-gated and runtime-gated; older builds retain the on-screen indicator.
@MainActor
final class CapsLEDController: ObservableObject {
    @Published private(set) var status = "Caps Lock LED: 아직 확인하지 않음"
    @Published private(set) var isAvailable = false
    @Published private(set) var isPulsing = false
    var onStatusChange: ((String) -> Void)?
    private var backend: (any CapsLEDBackend)?
    private var pulseTask: Task<Void, Never>?
    private var isProbing = false

    nonisolated init() {}

    private func report(_ message: String) {
        status = message
        onStatusChange?(message)
    }

    /// Read-only capability detection; no output report is written during discovery.
    func probe() async {
        guard !isProbing, !isPulsing else { return }
        isProbing = true
        defer { isProbing = false }
        backend?.stop()
        backend = nil
        isAvailable = false
        #if canImport(CoreHID)
        if #available(macOS 15.0, *) {
            let device = CoreHIDCapsLEDBackend()
            backend = device
            device.onChange = { [weak self] available, message in
                guard let self else { return }
                self.isAvailable = available
                if !available { self.pulseTask?.cancel() }
                self.report(message)
            }
            report("Caps Lock LED: 읽기 전용 장치 확인 중…")
            await device.start()
            return
        }
        #endif
        report("Caps Lock LED 미지원: macOS 15 이상과 CoreHID SDK로 빌드한 앱이 필요합니다. 화면 표시를 사용하세요.")
    }

    /// Only an explicit UI opt-in may enable writes. Capability reads are not a write test.
    func pulse(count: Int, userOptedIn: Bool) async {
        guard userOptedIn else { report("Caps Lock LED: 먼저 LED 사용에 동의하세요."); return }
        guard (1...10).contains(count) else { report("Caps Lock LED: 횟수는 1–10이어야 합니다."); return }
        guard !isPulsing, !isProbing else { return }
        guard isAvailable, let backend else { report("Caps Lock LED: 지원 장치를 먼저 확인하세요."); return }
        isPulsing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var original: UInt8?
            var result = "완료"
            do {
                // Refresh immediately before writing; never guess the initial state.
                original = try await backend.read()
                try Task.checkCancellation()
                self.report("Caps Lock LED: \(count)회 표시 중 (초당 1회)")
                for _ in 0..<count {
                    try Task.checkCancellation()
                    try await backend.write(1)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    try await backend.write(0)
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch is CancellationError {
                result = "취소됨"
            } catch {
                result = "오류: \(error.localizedDescription)"
            }
            if let original {
                // A fresh unstructured task is not cancelled with the pulse task.
                // Always attempt restoration, even after a failed or interrupted write.
                let restoration = Task { @MainActor () -> String? in
                    do {
                        try await backend.write(original)
                        guard try await backend.read() == original else {
                            return "복원 후 읽은 LED 상태가 원래 상태와 다릅니다."
                        }
                        return nil
                    } catch { return error.localizedDescription }
                }
                if let failure = await restoration.value {
                    self.isAvailable = false
                    self.report("Caps Lock LED \(result). 원래 LED 상태 복원 실패: \(failure). 키보드 연결과 LED 상태를 직접 확인하세요.")
                } else {
                    self.report("Caps Lock LED \(result). 원래 LED 상태로 복원했습니다.")
                }
            } else {
                self.report("Caps Lock LED \(result). 초기 상태를 읽지 못해 LED를 변경하지 않았습니다.")
            }
            self.isPulsing = false
            self.pulseTask = nil
        }
        pulseTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Await this before application termination so restoration can finish.
    func cancel() async {
        guard let task = pulseTask else { return }
        task.cancel()
        await task.value
    }
}

@MainActor
private protocol CapsLEDBackend: AnyObject {
    func read() async throws -> UInt8
    func write(_ value: UInt8) async throws
    func stop()
}

private struct CapsLEDError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

#if canImport(CoreHID)
/// Public API reference (verified against Apple's documentation, not hardware tested):
/// https://developer.apple.com/documentation/corehid/communicatingwithhiddevices
/// https://developer.apple.com/documentation/corehid/hiddeviceclient/updateelements(_:timeout:)
@available(macOS 15.0, *)
@MainActor
private final class CoreHIDCapsLEDBackend: CapsLEDBackend {
    var onChange: ((Bool, String) -> Void)?
    private let manager = HIDDeviceManager()
    private var discovery: Task<Void, Never>?
    private var client: HIDDeviceClient?
    private var element: HIDElement?
    private var connected = false
    private var selected = false

    func start() async {
        discovery = Task { @MainActor [weak self] in
            guard let self else { return }
            let criteria = HIDDeviceManager.DeviceMatchingCriteria(primaryUsage: .genericDesktop(.keyboard))
            do {
                for try await notification in await self.manager.monitorNotifications(matchingCriteria: [criteria]) {
                    try Task.checkCancellation()
                    switch notification {
                    case .deviceMatched(let reference):
                        // Pick one device only. A new probe is required to switch keyboards.
                        guard !self.selected, let candidate = HIDDeviceClient(deviceReference: reference) else { continue }
                        let elements = await candidate.elements
                        try Task.checkCancellation()
                        guard let led = elements.first(where: { $0.usage == .led(.capsLock) && $0.type == .output }) else { continue }
                        self.client = candidate
                        self.element = led
                        self.connected = true
                        do {
                            _ = try await self.read()
                            try Task.checkCancellation()
                            self.selected = true
                            let name = await candidate.product ?? "키보드"
                            self.onChange?(true, "Caps Lock LED: \(name)의 출력 요소와 현재 상태 읽기 확인. 쓰기 및 실제 LED 동작은 아직 미검증.")
                        } catch is CancellationError {
                            return
                        } catch {
                            self.client = nil
                            self.element = nil
                            self.connected = false
                            self.onChange?(false, "Caps Lock LED 읽기 실패: \(error.localizedDescription). 권한 또는 장치 지원을 확인하세요.")
                        }
                    case .deviceRemoved(let reference):
                        if let client = self.client, client.deviceReference == reference {
                            self.connected = false
                            self.onChange?(false, "Caps Lock LED: 선택한 키보드 연결이 끊겼습니다. 재연결 후 다시 확인하세요.")
                        }
                    default: continue
                    }
                }
            } catch is CancellationError { /* Explicit stop. */ }
            catch {
                self.connected = false
                self.onChange?(false, "Caps Lock LED 장치 확인 실패: \(error.localizedDescription)")
            }
        }
        // Discovery continues after this bounded initial wait, including removal notices.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if !selected {
            onChange?(false, "Caps Lock LED: 읽을 수 있는 출력 요소가 아직 없습니다. 장치 미지원 또는 접근 권한 문제일 수 있습니다. 화면 표시를 사용하세요.")
        }
    }

    func read() async throws -> UInt8 {
        guard connected, let client, let element else { throw CapsLEDError(message: "장치가 연결되어 있지 않습니다.") }
        let request = HIDDeviceClient.RequestElementUpdate(elements: [element], pollDevice: true)
        let results = await client.updateElements([request], timeout: .seconds(2))
        guard let response = results[request], let value = try response.get().first else {
            throw CapsLEDError(message: "LED 현재 상태 응답이 없습니다.")
        }
        let state = value.integerValue(asTypeTruncatingIfNeeded: UInt8.self)
        guard state == 0 || state == 1 else { throw CapsLEDError(message: "지원하지 않는 LED 상태 값입니다.") }
        return state
    }

    func write(_ value: UInt8) async throws {
        guard connected, let client, let element else { throw CapsLEDError(message: "장치 연결이 끊겨 LED를 쓸 수 없습니다.") }
        let value = HIDElement.Value(element: element, fromIntegerTruncatingIfNeeded: value, timestamp: SuspendingClock.now)
        let request = HIDDeviceClient.ProvideElementUpdate(values: [value])
        let results = await client.updateElements([request], timeout: .seconds(2))
        guard let result = results[request] else { throw CapsLEDError(message: "LED 쓰기 결과가 없습니다.") }
        try result.get()
    }

    func stop() {
        discovery?.cancel()
        discovery = nil
        connected = false
    }
}
#endif
