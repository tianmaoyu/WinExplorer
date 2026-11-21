import AppKit
import Carbon.HIToolbox

/// 系统级快捷键。用 Carbon 的 RegisterEventHotKey：
/// 不需要「辅助功能」授权，也不会被前台 App 抢走。
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// 默认 ⌥⌘E（E 对应 Explorer）
    static let defaultKeyCode = UInt32(kVK_ANSI_E)
    static let defaultModifiers = UInt32(cmdKey | optionKey)

    static var shortcutText: String { "⌥⌘E" }

    var onTrigger: (() -> Void)?
    private(set) var isRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    @discardableResult
    func register(
        keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
        modifiers: UInt32 = GlobalHotKey.defaultModifiers
    ) -> Bool {
        guard !isRegistered else { return true }
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x5745_5850), id: 1) // 'WEXP'
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            return false
        }
        isRegistered = true
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        isRegistered = false
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.onTrigger?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
