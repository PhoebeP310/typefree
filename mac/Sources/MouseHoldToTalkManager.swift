import Cocoa
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

enum MouseHoldToTalkSettings {
    static let enabledKey = "mouse_hold_to_talk_enabled"
    /// 3.0 起默认开（新功能引导会演示；想关去「设置 → 探索」）
    static let defaultEnabled = true
    /// 随时问 AI（长按空白处）的开关；和「鼠标长按说话」各管各的，任一开着监听器就工作
    static let askEnabledKey = "mouse_hold_ask_enabled"
    static let askDefaultEnabled = true
    /// 按住多久算「长按」。普通点击通常 0.1～0.2 秒；再短会把慢点击误判成长按。
    static let holdThreshold: TimeInterval = 0.45
    /// 按下后多久做一次预热查询（让 Chromium 类 App 开始算精确命中）
    static let warmUpDelay: TimeInterval = 0.12
    /// 按下后指针移动超过这个距离（点）就当成拖拽，不再触发
    static let moveTolerance: CGFloat = 6
    /// 问 AI 已开始录音、还没判断出开口时，指针移动超过这个距离就当成在 App 里拖选文字，悄悄撤销。
    /// 比 moveTolerance 宽得多：收音小时可能一直判断不出开口，边说边轻微挪动鼠标不能把问题丢掉。
    static let askPendingMoveTolerance: CGFloat = 20
    /// 微信自带「按住鼠标语音输入」约 0.45～0.5 秒后开麦（2026-09 实测 4.1.x）。在它之前给微信合成一个
    /// 「松开」，微信就当成普通单击、不会进入自己的语音输入；用户继续按着，由我们接管录音。
    static let wechatPreemptDelay: TimeInterval = 0.25
    /// 拖开取消：死区内不显示任何东西；拖过 armDistance 进入「待取消」，拖回 disarmDistance 以内解除
    static let cancelDeadZone: CGFloat = 15
    static let cancelArmDistance: CGFloat = 70
    static let cancelDisarmDistance: CGFloat = 45
    /// 到点后朝胶囊方向累计移动这么多就解除（用户看得见胶囊、记不住原点）
    static let cancelTowardCapsuleDistance: CGFloat = 25
    /// 解除后再背离胶囊累计移动这么多才重新到点
    static let cancelAwayFromCapsuleDistance: CGFloat = 30
    /// 拖开的方向与「原点→胶囊」方向夹角小于这个角度 = 朝胶囊拖，不算到点
    static let cancelTowardCapsuleAngle: CGFloat = 40
    /// 通常下拉 24pt 即锁定；靠近 Dock / 屏幕底部时缩短，仍保留 10pt 防抖距离。
    static let lockArmDistance: CGFloat = 24
    static let lockMinDistance: CGFloat = 10
    /// 胶囊外沿再留 8pt，靠近即可锁定，不用精确瞄准。
    static let capsuleLockPadding: CGFloat = 8
    static func lockDistance(availableBelow: CGFloat) -> CGFloat {
        min(lockArmDistance, max(lockMinDistance, availableBelow / 2))
    }
    static let holdPollInterval: TimeInterval = 1.0 / 60.0

    static var isEnabled: Bool {
        VoicePolishConfig.shared.bool(forKey: enabledKey, defaultValue: defaultEnabled)
    }
    static var isAskEnabled: Bool {
        VoicePolishConfig.shared.bool(forKey: askEnabledKey, defaultValue: askDefaultEnabled)
    }
}

/// 按住期间的「拖开取消」手势快照（AppKit 屏幕坐标，左下原点）
struct MouseHoldGesture {
    let anchor: NSPoint
    let cursor: NSPoint
    let distance: CGFloat
    let progress: CGFloat
    let armed: Bool
}

/// 鼠标长按说话（实验功能）：在输入框上按住左键约半秒开始录音，松开即停；下拉锁定后松手继续。
/// 只旁观事件、不拦截、不吞事件——输入框里按下只是把光标放过去，松手什么也不触发，所以安全；
/// 按在别处（按钮、列表、图片……）一律不触发。判定逻辑在 TextInputLocator，跨进程查询放后台队列。
final class MouseHoldToTalkManager {
    private struct LockedDrag {
        var capsuleCenter: NSPoint
        var closestDistance: CGFloat
        var peakDistance: CGFloat
    }

    private struct Press {
        let id: Int
        let downPoint: CGPoint
        let pid: pid_t
        let bundleID: String?
        let appName: String
        /// 按在自家窗口（新功能引导的「试一试」输入框）上：只允许输入框长按说话，不触发问 AI
        var recording = false
        /// 已向目标 App 合成过「松开」：系统层面的按键状态已不可信，只认硬件层状态 / 真实松开事件
        var preempted = false
        /// 按下点（AppKit 屏幕坐标），拖开取消的原点
        let downLocation: NSPoint
        /// 按下时固定门槛，避免 Dock 显隐改变可用区域后门槛突然跳动。
        var lockDistance = MouseHoldToTalkSettings.lockArmDistance
        /// 拖开取消：当前是否处于「松手即取消」
        var armed = false
        /// 锁定后普通松手继续录音；按住拖远进入待取消时，松手才取消。
        var locked = false
        /// nil 表示已经松手，普通鼠标移动不再参与取消判定。
        var lockedDrag: LockedDrag?
        /// 上一帧的指针位置（算「朝胶囊 / 背离胶囊」的累计位移）
        var lastCursor: NSPoint?
        /// 朝胶囊方向的累计位移（背离时回落）
        var towardAccum: CGFloat = 0
        /// 背离胶囊方向的累计位移（靠近时回落）
        var awayAccum: CGFloat = 0
        /// 这次按住里解除过取消（之后重新到点要先背离胶囊）
        var wasDisarmed = false
        /// 问 AI 已开始录音、但还没判断出开口：按键还留在 App 手里（没合成「松开」）。
        /// 这期间拖动 = 在 App 里选字，悄悄撤销问 AI；松手照常识别（收音小时可能一直判断不出开口）
        var awaitingSpeech = false
        /// 设置窗（工单输入框等）只放行输入框长按说话，空白处不问 AI；引导页仍可以问 AI
        var askAllowed = true
    }

    private let onStart: () -> Bool
    private let onStop: () -> Void
    private let isRecording: () -> Bool

    private var monitor: Any?
    private var localMonitor: Any?
    private var press: Press?
    private var pressCounter = 0
    private var decisionWork: DispatchWorkItem?
    private var preemptWork: DispatchWorkItem?
    /// 抢跑之后用来盯硬件层按键状态的定时器（见 sendWeChatPreempt）
    private var physicalReleasePoller: Timer?
    private var didLogDisabledPress = false
    /// 我们自己合成的事件带这个标记，监听器看到就忽略，免得把自己发的「松开」当成用户松手
    private static let syntheticTag: Int64 = 0x5459_5046_4D48
    private lazy var syntheticSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = Self.syntheticTag
        return source
    }()
    private let axQueue = DispatchQueue(label: "com.voicepolish.mouse-hold-to-talk.ax", qos: .userInitiated)

    var debugLog: ((String) -> Void)?
    /// 拖开取消：待取消状态下松手时调用（代替 onStop）
    var onCancel: (() -> Void)?
    var onLock: (() -> Void)?
    /// 长按在非输入框、又不是能点的东西上：开始「问 AI」录音（返回 false = 不开始）。nil = 不支持问 AI
    var onStartAsk: (() -> Bool)?
    /// 自己 App 的窗口一律不触发，唯独新功能引导窗里的「试一试」输入框放行：返回引导窗的窗口编号
    var guideWindowNumber: (() -> Int?)?
    /// 设置窗（工单输入框、词库、提示词等）里的输入框也放行长按说话，但空白处不问 AI：返回设置窗的窗口编号
    var dictationWindowNumber: (() -> Int?)?
    /// 问 AI 在判断出开口前被拖动（是在 App 里选字）：悄悄丢掉录音，不提示
    var onAbortAsk: (() -> Void)?
    /// 鼠标长按录音开始（按键已交还系统、手势跟踪开始），参数为按下点
    var onHoldStarted: ((NSPoint) -> Void)?
    /// 按住期间每帧的手势快照
    var onHoldGestureUpdate: ((MouseHoldGesture) -> Void)?
    /// 手势结束（松手 / 被别的途径停掉），参数为是否取消
    var onHoldGestureEnded: ((Bool) -> Void)?
    /// 录音胶囊此刻在屏幕上的中心（AppKit 坐标）；「朝胶囊移动 = 不取消」的参照
    var capsuleCenterProvider: (() -> NSPoint?)?
    /// 胶囊可见本体的屏幕坐标，不包含窗口四周为光晕预留的透明区域。
    var capsuleFrameProvider: (() -> NSRect?)?

    init(
        onStart: @escaping () -> Bool,
        onStop: @escaping () -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.onStart = onStart
        self.onStop = onStop
        self.isRecording = isRecording
        startListening()
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        cancelPending()
        press = nil
    }

    /// 录音被别的途径（快捷键、菜单、出错）停掉时由 App 调用，避免我们之后又去 onStop 一次
    func recordingDidLeaveActiveState() {
        if press?.recording == true {
            debugLog?("recording ended elsewhere, dropping press")
            cancelPending()
            press = nil
            onHoldGestureEnded?(false)
        }
    }

    /// 问 AI 听到用户开口：此刻才把按键从 App 手里接过来（与输入框长按开始时相同），
    /// 拖开取消、下拉锁定从这里开始生效。
    func askSpeechDetected() {
        guard var current = press, current.recording, current.awaitingSpeech else { return }
        current.awaitingSpeech = false
        press = current
        debugLog?("press #\(current.id) ask: speech detected → take over the hold")
        releaseButtonForApp(pressID: current.id, point: current.downPoint, reason: "ask speech")
        onHoldStarted?(current.downLocation)
    }

    /// 已松手的锁定录音，只允许从胶囊本体重新开始取消拖拽。
    func beginLockedCapsuleDrag(at cursor: NSPoint) -> Bool {
        guard isRecording(), var current = press, current.locked,
              current.lockedDrag == nil, isNearCapsule(cursor) else { return false }
        current.lockedDrag = makeLockedDrag(at: cursor, fallback: current.downLocation)
        current.armed = false
        press = current
        return true
    }

    func updateLockedCapsuleDrag(at cursor: NSPoint) {
        guard let current = press, current.locked, current.lockedDrag != nil else { return }
        trackCancelGesture(pressID: current.id, cursor: cursor)
    }

    func endLockedCapsuleDrag(at cursor: NSPoint) {
        guard press?.lockedDrag != nil else { return }
        releasePress(via: "capsule drag", cursor: cursor)
    }

    private func startListening() {
        // 全局监听收不到本 App 自己窗口里的事件——正好，设置窗里不该触发。
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.dispatch(event)
        }
        // 自己窗口里的事件只能靠本地监听拿到；只放行新功能引导窗（「试一试」输入框），其余窗口照旧不触发。
        // 本地监听必须把事件原样还回去，否则窗口本身收不到点击。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            guard let self else { return event }
            let allowed = [self.guideWindowNumber?(), self.dictationWindowNumber?()].compactMap { $0 }
            // 松开/拖动没有 window 归属时也要送到（按住期间指针可能已离开窗口）
            if let number = event.window?.windowNumber, allowed.contains(number) {
                self.dispatch(event)
            } else if event.type != .leftMouseDown, self.press != nil {
                self.dispatch(event)
            }
            return event
        }
    }

    private func dispatch(_ event: NSEvent) {
        if let cg = event.cgEvent, cg.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return }
        switch event.type {
        case .leftMouseDown: handleMouseDown(event)
        case .leftMouseDragged: handleMouseDragged(event)
        case .leftMouseUp: handleMouseUp(event)
        default: break
        }
    }

    /// 监听器是否装上了（全局监听在极少数情况下会返回 nil）
    var isListening: Bool { monitor != nil }

    // MARK: - 事件

    private func handleMouseDown(_ event: NSEvent) {
        cancelPending()
        guard MouseHoldToTalkSettings.isEnabled || MouseHoldToTalkSettings.isAskEnabled else {
            if !didLogDisabledPress {
                didLogDisabledPress = true
                debugLog?("mouse-down seen while feature is off (logged once per launch)")
            }
            return
        }
        guard !isRecording() else { debugLog?("down ignored: already recording"); return }
        // 带修饰键的点击（⌘点开新标签、⇧点选区）和双击的第二下都不碰，避免和系统手势打架
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { debugLog?("down ignored: modifiers"); return }
        guard event.clickCount <= 1 else { debugLog?("down ignored: clickCount=\(event.clickCount)"); return }
        guard let cg = event.cgEvent else { debugLog?("down ignored: no cgEvent"); return }

        let point = cg.location
        // 注意：eventTargetUnixProcessID 在全局监听里填的是「收到这份拷贝的我们自己」，不能用。
        // 用事件自带的「指针下窗口编号」反查窗口所有者，拿不到再按坐标扫窗口列表。
        var pid: pid_t = 0
        let windowID = CGWindowID(truncatingIfNeeded: cg.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        if windowID != 0 { pid = WindowLookup.ownerPID(ofWindow: windowID) ?? 0 }
        if pid <= 0 { pid = WindowLookup.ownerPID(at: point) ?? 0 }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let onGuideWindow = pid == ownPID && windowID != 0 && guideWindowNumber?() == Int(windowID)
        let onSettingsWindow = pid == ownPID && windowID != 0 && dictationWindowNumber?() == Int(windowID)
        guard pid > 0, pid != ownPID || onGuideWindow || onSettingsWindow else { debugLog?("down ignored: pid=\(pid)"); return }
        let running = NSRunningApplication(processIdentifier: pid)

        pressCounter += 1
        let downLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(downLocation, $0.frame, false) }
        let availableBelow = screen.map { downLocation.y - $0.visibleFrame.minY }
        var current = Press(
            id: pressCounter,
            downPoint: point,
            pid: pid,
            bundleID: running?.bundleIdentifier,
            appName: running?.localizedName ?? "pid \(pid)",
            downLocation: downLocation,
            lockDistance: availableBelow.map { MouseHoldToTalkSettings.lockDistance(availableBelow: $0) }
                ?? MouseHoldToTalkSettings.lockArmDistance
        )
        current.askAllowed = !onSettingsWindow || onGuideWindow
        press = current
        debugLog?("down #\(current.id) at \(TextInputLocator.fmt(point)) app=\(current.appName)")

        let pressID = current.id
        axQueue.asyncAfter(deadline: .now() + MouseHoldToTalkSettings.warmUpDelay) { [weak self] in
            guard let self, self.pressIsAlive(pressID) else { return }
            TextInputLocator.warmUp(point: point, pid: pid)
        }

        let work = DispatchWorkItem { [weak self] in self?.decide(pressID: pressID) }
        decisionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MouseHoldToTalkSettings.holdThreshold, execute: work)

        if let bundleID = current.bundleID, WeChatInputRegion.bundleIDs.contains(bundleID) {
            scheduleWeChatPreempt(pressID: pressID, point: point, pid: pid, startedAt: ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: - 微信抢跑

    /// 微信输入区域里的按下：先在后台确认位置，再在 0.25s 时给微信合成一个「松开」。
    private func scheduleWeChatPreempt(pressID: Int, point: CGPoint, pid: pid_t, startedAt: TimeInterval) {
        axQueue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, TextInputLocator.messagingTimeout)
            let verdict = WeChatInputRegion.verdict(point: point, app: app) { _ in }
            guard verdict.isEditable else { return }
            DispatchQueue.main.async {
                guard let self, self.press?.id == pressID, self.press?.recording == false else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let delay = max(0, MouseHoldToTalkSettings.wechatPreemptDelay - elapsed)
                let work = DispatchWorkItem { [weak self] in self?.releaseButtonForApp(pressID: pressID, point: point, reason: "wechat preempt") }
                self.preemptWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    /// 把这次按住从目标 App 手里拿回来：给它合成一个「松开」，它当成一次普通单击（光标已放好），
    /// 之后鼠标怎么动都不会在它那里拖选文字；我们靠硬件层按键状态判断用户何时真正松手。
    /// 微信在 0.25s 就要做（避开它自带的语音输入）；其他 App 在录音开始时做。
    private func releaseButtonForApp(pressID: Int, point: CGPoint, reason: String) {
        guard var current = press, current.id == pressID, !current.preempted else { return }
        guard Self.physicalLeftButtonDown() else { return }
        guard let source = syntheticSource,
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            debugLog?("preempt #\(pressID): failed to build synthetic mouse-up")
            return
        }
        // 注入到会话层而不是硬件层：硬件层的按键状态保持「仍按着」，用户真正松手时系统才会照常发出松开事件；
        // 微信照样能收到这个合成的「松开」。
        up.post(tap: .cgSessionEventTap)
        current.preempted = true
        press = current
        debugLog?("release-to-app #\(pressID) (\(reason)): synthetic mouse-up sent, keeping the hold")

        // 合成「松开」之后，系统认为按键已经松开，用户真正松手时不会再给我们发松开事件（实测如此）。
        // 只能盯着硬件层的按键状态，一变成松开就按松手处理。
        physicalReleasePoller?.invalidate()
        let poller = Timer(timeInterval: MouseHoldToTalkSettings.holdPollInterval, repeats: true) { [weak self] timer in
            guard let self, let live = self.press, live.id == pressID else { timer.invalidate(); return }
            if !Self.physicalLeftButtonDown() {
                timer.invalidate()
                self.physicalReleasePoller = nil
                self.releasePress(via: "physical button state")
                return
            }
            if live.recording { self.trackCancelGesture(pressID: pressID) }
        }
        RunLoop.main.add(poller, forMode: .common)
        physicalReleasePoller = poller
    }

    // MARK: - 拖开取消

    private func trackCancelGesture(pressID: Int, cursor: NSPoint = NSEvent.mouseLocation) {
        guard var current = press, current.id == pressID, current.recording else { return }
        if current.locked {
            trackLockedCancelGesture(current: current, cursor: cursor)
            return
        }
        let downward = current.downLocation.y - cursor.y // AppKit 屏幕坐标向上为正
        let sideways = abs(cursor.x - current.downLocation.x)
        let distance = hypot(cursor.x - current.downLocation.x, cursor.y - current.downLocation.y)
        let nearCapsule = isNearCapsule(cursor)
        // 胶囊出现在指针下方时不能自动锁定，仍须有明确的鼠标移动。
        let lockByCapsule = nearCapsule && distance >= MouseHoldToTalkSettings.lockMinDistance
        let lockByDownwardDrag = downward >= current.lockDistance && downward > sideways
        // 锁定优先于取消：从红色取消区移回胶囊，直接变绿，松手不会再取消。
        if lockByCapsule || lockByDownwardDrag {
            current.locked = true
            current.armed = false
            current.lockedDrag = makeLockedDrag(at: cursor, fallback: current.downLocation)
            press = current
            debugLog?("press #\(pressID) locked via \(lockByCapsule ? "capsule" : "downward drag")")
            onLock?()
            return
        }
        let dead = MouseHoldToTalkSettings.cancelDeadZone
        let arm = MouseHoldToTalkSettings.cancelArmDistance
        let disarm = MouseHoldToTalkSettings.cancelDisarmDistance
        let toward = MouseHoldToTalkSettings.cancelTowardCapsuleDistance
        let away = MouseHoldToTalkSettings.cancelAwayFromCapsuleDistance
        let progress = max(0, min(1, (distance - dead) / (arm - dead)))
        // 以胶囊为参照：朝胶囊移动 = 不取消。拿不到胶囊位置时退化为只看原点。
        let capsule = capsuleCenterProvider?()
        if let capsule, let last = current.lastCursor {
            let toCap = CGVector(dx: capsule.x - cursor.x, dy: capsule.y - cursor.y)
            let len = hypot(toCap.dx, toCap.dy)
            if len > 1 {
                let along = ((cursor.x - last.x) * toCap.dx + (cursor.y - last.y) * toCap.dy) / len
                if along > 0 {
                    current.towardAccum += along
                    current.awayAccum = max(0, current.awayAccum - along)
                } else {
                    current.awayAccum += -along
                    current.towardAccum = max(0, current.towardAccum + along)
                }
            }
        }
        current.lastCursor = cursor
        var armedNow = current.armed
        if current.armed {
            // 朝胶囊累计移动 25pt 即解除；回到原点 45pt 内也解除
            if current.towardAccum >= toward || distance <= disarm {
                armedNow = false
                current.wasDisarmed = true
                current.towardAccum = 0
                current.awayAccum = 0
            }
        } else {
            // 拖开 70pt 到点，但朝着胶囊拖的不算（与「原点→胶囊」夹角 < 40°）；解除过的要先背离胶囊 30pt
            var directionOK = true
            if let capsule, distance > 1 {
                let dragDir = CGVector(dx: (cursor.x - current.downLocation.x) / distance, dy: (cursor.y - current.downLocation.y) / distance)
                let oc = CGVector(dx: capsule.x - current.downLocation.x, dy: capsule.y - current.downLocation.y)
                let ocLen = hypot(oc.dx, oc.dy)
                if ocLen > 1 {
                    let cosine = max(-1, min(1, (dragDir.dx * oc.dx + dragDir.dy * oc.dy) / ocLen))
                    let angle = acos(cosine) * 180 / .pi
                    directionOK = angle > MouseHoldToTalkSettings.cancelTowardCapsuleAngle
                }
            }
            let reArmOK = !current.wasDisarmed || current.awayAccum >= away
            // 向下为主的拖动留给锁定，避免未到锁定距离时先闪出红色取消提示。
            if distance >= arm && directionOK && reArmOK && downward <= sideways {
                armedNow = true
                current.towardAccum = 0
                current.awayAccum = 0
            }
        }
        if armedNow != current.armed {
            debugLog?("press #\(pressID) cancel gesture \(armedNow ? "armed" : "disarmed") at \(Int(distance))pt")
        }
        current.armed = armedNow
        press = current
        onHoldGestureUpdate?(MouseHoldGesture(anchor: current.downLocation, cursor: cursor, distance: distance, progress: progress, armed: armedNow))
    }

    private func isNearCapsule(_ cursor: NSPoint) -> Bool {
        guard let frame = capsuleFrameProvider?() else { return false }
        let hitFrame = frame.insetBy(dx: -MouseHoldToTalkSettings.capsuleLockPadding,
                                    dy: -MouseHoldToTalkSettings.capsuleLockPadding)
        return NSBezierPath(roundedRect: hitFrame, xRadius: hitFrame.height / 2,
                            yRadius: hitFrame.height / 2).contains(cursor)
    }

    private func makeLockedDrag(at cursor: NSPoint, fallback: NSPoint) -> LockedDrag {
        let center = capsuleCenterProvider?() ?? fallback
        let distance = hypot(cursor.x - center.x, cursor.y - center.y)
        return LockedDrag(capsuleCenter: center, closestDistance: distance, peakDistance: distance)
    }

    private func trackLockedCancelGesture(current: Press, cursor: NSPoint) {
        var current = current
        guard var drag = current.lockedDrag else { return } // 已松手，任意移动都不取消。
        let center = capsuleCenterProvider?() ?? drag.capsuleCenter
        let distance = hypot(cursor.x - center.x, cursor.y - center.y)
        if center != drag.capsuleCenter {
            // 屏幕拔插挪动了胶囊时重新取参照，不能因为窗口移动而取消录音。
            drag = makeLockedDrag(at: cursor, fallback: center)
            current.armed = false
        }
        if isNearCapsule(cursor) {
            drag.closestDistance = current.armed ? distance : min(drag.closestDistance, distance)
            current.armed = false
            drag.peakDistance = distance
        } else if current.armed {
            drag.peakDistance = max(drag.peakDistance, distance)
            if drag.peakDistance - distance >= MouseHoldToTalkSettings.cancelTowardCapsuleDistance {
                current.armed = false
                drag.closestDistance = distance
                drag.peakDistance = distance
            }
        } else {
            drag.closestDistance = min(drag.closestDistance, distance)
            if distance - drag.closestDistance >= MouseHoldToTalkSettings.cancelArmDistance {
                current.armed = true
                drag.peakDistance = distance
            }
        }
        current.lockedDrag = drag
        press = current
        onHoldGestureUpdate?(MouseHoldGesture(anchor: center, cursor: cursor, distance: distance,
            progress: max(0, min(1, (distance - drag.closestDistance) / MouseHoldToTalkSettings.cancelArmDistance)),
            armed: current.armed))
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard let current = press, let cg = event.cgEvent else { return }
        let p = cg.location
        let moved = hypot(p.x - current.downPoint.x, p.y - current.downPoint.y)
        if current.recording {
            // 问 AI 还没开口就拖动：是在 App 里选字 / 拖东西，悄悄撤销；拖动事件本来就照常归 App
            guard current.awaitingSpeech, moved > MouseHoldToTalkSettings.askPendingMoveTolerance else { return }
            debugLog?("press #\(current.id) ask: moved \(Int(moved))pt before speaking → abort")
            abortPendingAsk()
            return
        }
        if moved > MouseHoldToTalkSettings.moveTolerance {
            debugLog?("press #\(current.id) moved \(Int(moved))pt → treated as drag")
            cancelPending()
            press = nil
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        releasePress(via: "up event")
    }

    private func releasePress(via source: String, cursor: NSPoint = NSEvent.mouseLocation) {
        if let current = press, current.awaitingSpeech {
            // 没判断出开口不代表没说话（2026-09-11：离 MacBook 麦克风远时说话峰值才 0.05～0.2），照常送去识别
            debugLog?("release #\(current.id) (\(source)) before speech detected → recognize anyway")
            cancelPending()
            press = nil
            onStop()
            return
        }
        // 松手前再采样一次，覆盖快速下拉后在两次轮询之间松手的情况。
        if let current = press, current.recording {
            trackCancelGesture(pressID: current.id, cursor: cursor)
        }
        guard var current = press else { return }
        cancelPending()
        if current.recording, current.locked, !current.armed {
            current.lockedDrag = nil
            press = current
            debugLog?("release #\(current.id) (\(source)) while locked → keep recording")
            return
        }
        press = nil
        if current.recording {
            if current.armed {
                debugLog?("release #\(current.id) (\(source)) while armed → onCancel")
                onHoldGestureEnded?(true)
                onCancel?()
            } else {
                debugLog?("release #\(current.id) (\(source)) → onStop")
                onHoldGestureEnded?(false)
                onStop()
            }
        } else {
            debugLog?("release #\(current.id) (\(source)) before threshold → plain click")
        }
    }

    /// 硬件层的左键状态。合成「松开」只污染会话层状态（NSEvent.pressedMouseButtons 立刻变 0），
    /// 硬件层要到用户真正松手才变，所以抢跑之后只信这个。
    private static func physicalLeftButtonDown() -> Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
    }

    // MARK: - 判定

    private func decide(pressID: Int) {
        guard let current = press, current.id == pressID, !current.recording else { return }
        let stillDown = current.preempted ? Self.physicalLeftButtonDown() : (NSEvent.pressedMouseButtons & 1 != 0)
        guard stillDown else {
            debugLog?("press #\(pressID) already released at threshold")
            press = nil
            return
        }
        guard !isRecording() else { press = nil; return }

        let point = current.downPoint
        let pid = current.pid
        let bundleID = current.bundleID
        axQueue.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            var lines: [String] = []
            let verdict = TextInputLocator.classify(point: point, pid: pid, bundleID: bundleID) { lines.append($0) }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            DispatchQueue.main.async {
                guard let self else { return }
                for line in lines { self.debugLog?("  \(line)") }
                self.debugLog?("verdict #\(pressID) \(verdict.debugName) in \(elapsed)ms")
                self.applyVerdict(verdict, pressID: pressID)
            }
        }
    }

    private func applyVerdict(_ verdict: TextInputVerdict, pressID: Int) {
        guard var current = press, current.id == pressID, !current.recording else { return }
        var askMode = false
        // 自家引导页的空白处也放行问 AI（Ray 9-15：看完演示想立刻在引导页上试一下）；输入框仍走长按说话
        if case .askable = verdict, current.askAllowed, onStartAsk != nil, MouseHoldToTalkSettings.isAskEnabled {
            askMode = true
        } else if !verdict.isEditable || !MouseHoldToTalkSettings.isEnabled {
            // 只开了「随时问 AI」没开「鼠标长按说话」：输入框上按住不录音
            press = nil
            return
        }
        // 判定期间可能已经松手（松手事件会把 press 清掉，这里是双保险）
        guard current.preempted ? Self.physicalLeftButtonDown() : (NSEvent.pressedMouseButtons & 1 != 0) else {
            debugLog?("press #\(pressID) released during classify")
            press = nil
            return
        }
        guard !isRecording(), (askMode ? (onStartAsk?() ?? false) : onStart()) else {
            debugLog?("start ignored by app")
            press = nil
            return
        }
        current.recording = true
        current.awaitingSpeech = askMode
        press = current
        debugLog?("→ \(askMode ? "onStartAsk" : "onStart") via mouse hold (#\(pressID))")
        // 问 AI：先不接管按键，等用户开口（askSpeechDetected）再接管。按住文字停一下再拖着选字是常见动作，
        // 开口前就接管会让拖动选不上字、往下拖还被当成锁定。
        if askMode { return }
        // 录音开始即把按键交还给 App：之后拖动不会在输入框里拖选文字，也让「拖开取消」成为可能
        releaseButtonForApp(pressID: pressID, point: current.downPoint, reason: "hold started")
        onHoldStarted?(current.downLocation)
        if case .editableNearby(_, let input) = verdict {
            // 按在输入框边上：点击落在框外，主动把焦点放进输入框，松手后的文字才粘贴得进去
            axQueue.async { [weak self] in
                let err = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                DispatchQueue.main.async { self?.debugLog?("press #\(pressID) focused snapped input: \(err == .success ? "ok" : "err \(err.rawValue)")") }
            }
        }
    }

    private func abortPendingAsk() {
        cancelPending()
        press = nil
        onAbortAsk?()
    }

    private func pressIsAlive(_ pressID: Int) -> Bool {
        // 从后台队列查询，只读一次快照即可（Swift 值类型拷贝）；不精确也无妨，预热查询只是加速。
        press?.id == pressID
    }

    private func cancelPending() {
        decisionWork?.cancel()
        decisionWork = nil
        preemptWork?.cancel()
        preemptWork = nil
        physicalReleasePoller?.invalidate()
        physicalReleasePoller = nil
    }
}

/// 事件里拿不到目标进程时的兜底：按窗口层级找指针下最上层的普通窗口的所有者。
enum WindowLookup {
    static func ownerPID(ofWindow windowID: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = list.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid > 0 else { return nil }
        return pid
    }

    static func ownerPID(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return pid
        }
        return nil
    }
}
