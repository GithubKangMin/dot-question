import AppKit
import Carbon

/// Carbon consumes only explicitly registered keys. Each instance filters its own ID.
final class HotKey {
    private static var nextID: UInt32 = 1
    private let identifier: UInt32
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        identifier = Self.nextID; Self.nextID += 1
    }
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_R), modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)) -> OSStatus {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            var received = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &received)
            guard result == noErr, received.signature == 0x44515152, received.id == owner.identifier else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { owner.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return status }
        let id = EventHotKeyID(signature: 0x44515152, id: identifier)
        let result = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
        if result != noErr { unregister() }
        return result
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit { unregister() }
}
