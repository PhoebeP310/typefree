import Cocoa
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

class StatusBarController {
    private let statusItem: NSStatusItem
    private let appearanceObserver = AppearanceObservingView(frame: .zero)
    private weak var delegate: AppDelegate?
    private let micItem = NSMenuItem(title: "麦克风", action: nil, keyEquivalent: "")
    private let hotkeyHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(delegate: AppDelegate) {
        self.delegate = delegate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.addSubview(appearanceObserver)
            appearanceObserver.onAppearanceChange = { [weak self] in self?.refreshStatusBarIcon() }
        }
        refreshStatusBarIcon()

        let menu = NSMenu()
        menu.addItem(withTitle: "开始/停止录音", action: #selector(toggleRecording), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "打开 Typefree", action: #selector(openSettingsCenter), keyEquivalent: "")
            .target = self
        // 工单 #17：加词不用再进主窗口翻到词库页
        menu.addItem(withTitle: "个人词库…", action: #selector(openVocabulary), keyEquivalent: "")
            .target = self
        // 本地改动：只打开上游 Releases 页，不再叫「检查更新」
        menu.addItem(withTitle: "查看作者新版本", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
            .target = delegate
        menu.addItem(NSMenuItem.separator())
        menu.addItem(micItem)
        rebuildMicSubmenu()
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "纠正上次结果", action: #selector(showManualCorrection), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "复制最后一句", action: #selector(copyLastDeliveredText), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        updateHotkeyHint()
        menu.addItem(hotkeyHintItem)
        menu.addItem(withTitle: "打开辅助功能设置", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 Typefree", action: #selector(quitApp), keyEquivalent: "q")
            .target = self
        statusItem.menu = menu

        setProcessingMode(delegate.currentProcessingMode())

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMicListOrSelectionChanged),
            name: .voicePolishMicrophoneListDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMicListOrSelectionChanged),
            name: .voicePolishMicrophoneSelectionDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onHotkeySettingsChanged),
            name: .voicePolishHotkeyDidChange,
            object: nil
        )
    }

    @objc private func onMicListOrSelectionChanged() {
        rebuildMicSubmenu()
        refreshStatusBarIcon()
    }

    private func rebuildMicSubmenu() {
        let mgr = MicrophoneManager.shared
        let submenu = NSMenu()

        let defaultName = mgr.systemDefaultDeviceName ?? "未知"
        let defaultItem = NSMenuItem(
            title: "跟随系统默认（\(defaultName)）",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = MicrophoneManager.systemDefaultUID
        defaultItem.state = mgr.selectedUID == MicrophoneManager.systemDefaultUID ? .on : .off
        submenu.addItem(defaultItem)
        submenu.addItem(NSMenuItem.separator())

        for device in mgr.devices {
            let title = device.isBuiltIn ? "\(device.name)（推荐）" : device.name
            let item = NSMenuItem(title: title, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = mgr.selectedUID == device.uid ? .on : .off
            submenu.addItem(item)
        }

        micItem.submenu = submenu
    }

    @objc private func onHotkeySettingsChanged() {
        updateHotkeyHint()
    }

    private func updateHotkeyHint() {
        let shortcut = RecordingHotkeyShortcut.current.displayName
        let action = RecordingHotkeyBehavior.isTapToggleEnabled ? "长按/单击" : "长按"
        hotkeyHintItem.title = "快捷键：\(action) \(shortcut) 录音"
        hotkeyHintItem.isEnabled = false
    }

    private func refreshStatusBarIcon() {
        guard let baseIcon = NSImage(named: "statusbar-icon") else {
            statusItem.button?.title = "VP"
            statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            return
        }

        let displayIcon: NSImage
        if MicrophoneManager.shared.isUsingNonDefault {
            var tintedIcon: NSImage?
            statusItem.button?.effectiveAppearance.performAsCurrentDrawingAppearance {
                tintedIcon = baseIcon.withBlueDotOverlay()
            }
            displayIcon = tintedIcon ?? baseIcon
            displayIcon.isTemplate = false
        } else {
            displayIcon = baseIcon
            displayIcon.isTemplate = true
        }
        displayIcon.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = displayIcon
        statusItem.button?.title = ""
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        MicrophoneManager.shared.select(uid: uid)
    }

    func setTitle(_ title: String) {
        // Don't overwrite icon with text — icon is always shown
        // Title is only used as fallback when icon isn't available
        if statusItem.button?.image == nil {
            statusItem.button?.title = title
        }
    }

    func setProcessingMode(_ mode: ProcessingMode) {
        // 处理模式选择器已从 UI 移除（应用固定云端直出）。保留方法以兼容调用方。
    }

    @objc private func toggleRecording() {
        delegate?.toggleRecording()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func copyLastDeliveredText() {
        DispatchQueue.main.async {
            self.delegate?.copyLastDeliveredText()
        }
    }

    @objc private func showManualCorrection() {
        DispatchQueue.main.async {
            self.delegate?.showManualCorrection()
        }
    }

    @objc private func openSettingsCenter() {
        DispatchQueue.main.async {
            self.delegate?.showSettingsCenter()
        }
    }

    @objc private func openVocabulary() {
        DispatchQueue.main.async {
            self.delegate?.showVocabularySettings()
        }
    }

    @objc private func openAccessibilitySettings() {
        delegate?.openAccessibilitySettings()
    }

}

private extension NSImage {
    /// 在图标右下角合成一个小蓝点，用于状态栏角标
    func withBlueDotOverlay() -> NSImage? {
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        // 先把基础图标按模板着色为深色画上去
        let rect = NSRect(origin: .zero, size: size)
        NSColor.labelColor.set()
        rect.fill()
        draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)

        // 角标：右下角小蓝点
        let dotDiameter = max(size.width * 0.32, 5)
        let dot = NSRect(
            x: size.width - dotDiameter,
            y: 0,
            width: dotDiameter,
            height: dotDiameter
        )
        NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.95, alpha: 1).set()
        NSBezierPath(ovalIn: dot).fill()
        return result
    }
}
