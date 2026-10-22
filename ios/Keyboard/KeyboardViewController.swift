import UIKit
import VoicePolishCore

/// Typefree 键盘：语音 / 拼 / EN / 颜 四页。录音、识别、润色都在主 App 里做（键盘扩展拿不到麦克风），
/// 键盘只发指令、带上本次风格、收结果上屏。
final class KeyboardViewController: UIInputViewController {
    private enum UIState: Equatable {
        case idle
        case waitingForApp       // 刚跳去主 App 开待机，等用户回来
        case recording
        case processing
        case message(String)     // 短暂提示，几秒后回到 idle
    }

    private enum Mode: Int, CaseIterable {
        case voice, pinyin, english, kaomoji, reply

        /// 顶栏和左右滑只走这几页：英文直接在双拼里敲、回车上屏，英文页只从双拼的「英」键进
        static let tabs: [Mode] = [.voice, .pinyin, .kaomoji, .reply]

        var title: String {
            switch self {
            case .voice: return "语音"
            case .pinyin: return "拼"
            case .english: return "EN"
            case .kaomoji: return "颜"
            case .reply: return "回复"
            }
        }

        /// 字母键盘页矮一点，按键和系统键盘一样高；其余页内容多，高一些
        var height: CGFloat {
            switch self {
            case .pinyin, .english, .voice: return 280
            default: return 338
            }
        }
    }

    private static let modeKey = "keyboard_mode"
    private static let styleKey = "keyboard_style"
    private static let toneUsageKey = "keyboard_tone_last_used"
    private static let purposeKey = "keyboard_pending_purpose"

    /// 这次录音是要上屏的口述，还是回复页「说想法」
    private enum Purpose: String { case dictation, intent }
    private var pendingPurpose: Purpose {
        get { Purpose(rawValue: TypefreeShared.defaults.string(forKey: Self.purposeKey) ?? "") ?? .dictation }
        set { TypefreeShared.defaults.set(newValue.rawValue, forKey: Self.purposeKey) }
    }

    private let bridge = SharedBridge.shared
    private var state: UIState = .idle { didSet { render() } }
    private var pendingSessionID: String? {
        get { TypefreeShared.defaults.string(forKey: "keyboard_pending_session") }
        set { TypefreeShared.defaults.set(newValue, forKey: "keyboard_pending_session") }
    }
    private var lastInsertedSessionID: String? {
        get { TypefreeShared.defaults.string(forKey: "keyboard_last_inserted_session") }
        set { TypefreeShared.defaults.set(newValue, forKey: "keyboard_last_inserted_session") }
    }

    private var mode: Mode = .voice
    private var style = StyleSelection()
    private var segmentButtons: [UIButton] = []
    private let content = UIView()
    private var voicePanel: VoicePanel!
    private var pinyinPanel: PinyinPanel!
    private var headerRow: UIStackView!
    private var englishPanel: LetterPanel!
    private var kaomojiPanel: KaomojiPanel!
    private var replyPanel: ReplyPanel!
    private var heightConstraint: NSLayoutConstraint!
    private let logoLabel = UILabel()
    private var clipboardCache: (change: Int, text: String?) = (-1, nil)
    private var logoText = NSAttributedString()

    // 回复页
    private var replyMessage: String?
    private var replyIntent: String?
    private var lastClipboardChange = -1
    private var lastInsertedText: String?

    private var levelLink: CADisplayLink?
    private var startConfirmTimer: Timer?
    private var messageTimer: Timer?
    /// 刚从键盘跳去主 App：键盘被挤下去不算「录到一半离开」，别发 stop
    private var leavingForApp = false
    /// 各页面的 🌐 键：系统自带底部 🌐 时（全面屏 iPhone）隐藏，只在 Home 键机型上显示
    private var globeButtons: [UIButton] = []
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        ToneCustomization.reload()   // App 设置里改的 emoji / 名字 / 隐藏
        mode = Mode(rawValue: TypefreeShared.defaults.integer(forKey: Self.modeKey)) ?? .voice
        if let data = TypefreeShared.defaults.data(forKey: Self.styleKey),
           let saved = try? JSONDecoder().decode(StyleSelection.self, from: data) {
            style = saved
        }
        buildLayout()
        showMode(mode, animated: false)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DarwinNotifier.shared.observe(TypefreeShared.stateNotification) { [weak self] in
            self?.syncFromSnapshot()
        }
        refreshReturnTitles()
        if hasFullAccess { bridge.markKeyboardSeen() }   // 让 App 首页的「允许完全访问」这一步打勾
        if mode == .reply { loadClipboardForReply() }
        syncFromSnapshot()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLevelLink()
        pinyinPanel?.reset()
        // 切走键盘时还在录：停下，结果回来后下次出现时再上屏（跳去主 App 时除外）
        if leavingForApp {
            leavingForApp = false
        } else if state == .recording, let sessionID = pendingSessionID {
            sendCommand(.stop(sessionID: sessionID))
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let needsGlobe = needsInputModeSwitchKey
        for button in globeButtons where button.isHidden == needsGlobe { button.isHidden = !needsGlobe }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshReturnTitles()
    }

    // MARK: - 布局

    private var actions: KeyboardActions {
        KeyboardActions(
            insert: { [weak self] in self?.textDocumentProxy.insertText($0) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            returnKey: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            attachGlobe: { [weak self] button in
                guard let self else { return }
                button.addTarget(self, action: #selector(self.handleInputModeList(from:with:)), for: .allTouchEvents)
                button.isHidden = true
                self.globeButtons.append(button)
            },
            returnTitle: { [weak self] in self?.returnTitle ?? "换行" },
            moveCursor: { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: $0) },
            setMarked: { [weak self] text in
                self?.textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            },
            unmark: { [weak self] in self?.textDocumentProxy.unmarkText() }
        )
    }

    private var returnTitle: String {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .send: return "发送"
        case .search, .google, .yahoo: return "搜索"
        case .go, .route, .join: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        case .continue: return "继续"
        default: return "换行"
        }
    }

    private func buildLayout() {
        heightConstraint = view.heightAnchor.constraint(equalToConstant: Mode.voice.height)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        // 顶栏：标志 · 输入方式切换
        let logo = logoLabel
        let attachment = NSTextAttachment()
        attachment.image = KTheme.sfImage("waveform", 15, weight: .bold)?.withTintColor(KTheme.text, renderingMode: .alwaysOriginal)
        let logoText = NSMutableAttributedString(attachment: attachment)
        logoText.append(NSAttributedString(string: " Typefree", attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: KTheme.text]))
        logo.attributedText = logoText
        self.logoText = logoText
        logo.lineBreakMode = .byTruncatingTail
        logo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let segment = UIStackView()
        segment.axis = .horizontal
        segment.spacing = 0
        segment.backgroundColor = KTheme.well
        segment.layer.cornerRadius = 10
        segment.isLayoutMarginsRelativeArrangement = true
        segment.layoutMargins = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        for m in Mode.tabs {
            let b = UIButton(type: .custom)
            b.setTitle(m.title, for: .normal)
            b.tag = m.rawValue
            b.layer.cornerRadius = 8
            b.addTarget(self, action: #selector(segmentTapped(_:)), for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: m == .voice || m == .reply ? 46 : 38).isActive = true
            segmentButtons.append(b)
            segment.addArrangedSubview(b)
        }
        let header = UIStackView(arrangedSubviews: [logo, UIView(), segment])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        segment.setContentCompressionResistancePriority(.required, for: .horizontal)

        voicePanel = VoicePanel(style: style, actions: actions)
        style = voicePanel.style   // 老数据里的简洁 / 扩充已挪到篇幅
        voicePanel.onMicTap = { [weak self] in self?.micTapped() }
        voicePanel.onMicHoldBegan = { [weak self] in self?.micHoldBegan() ?? false }
        voicePanel.onMicHoldEnded = { [weak self] in self?.micHoldEnded($0) }
        voicePanel.onStyleChange = { [weak self] in self?.styleChanged($0, from: .voice) }
        pinyinPanel = PinyinPanel(actions: actions)
        pinyinPanel.onSwitchToEnglish = { [weak self] in self?.showMode(.english, animated: true) }
        pinyinPanel.onComposingChange = { [weak self] composing in
            self?.headerRow.alpha = composing ? 0 : 1
            self?.pinyinPanel.candidateBar.isHidden = !composing
        }
        englishPanel = LetterPanel(actions: actions)
        kaomojiPanel = KaomojiPanel(actions: actions)
        replyPanel = ReplyPanel(style: style, actions: actions)
        replyPanel.onStyleChange = { [weak self] in self?.styleChanged($0, from: .reply) }
        replyPanel.onGenerate = { [weak self] in self?.generateReplies() }
        replyPanel.onIntentMic = { [weak self] in self?.replyIntentTapped() }
        replyPanel.onClearIntent = { [weak self] in
            self?.replyIntent = nil
            self?.replyPanel.setIntent(nil)
            self?.generateReplies()
        }
        replyPanel.onPick = { [weak self] text in
            self?.lastInsertedText = text
            self?.textDocumentProxy.insertText(text)
        }
        for panel in [voicePanel!, pinyinPanel!, englishPanel!, kaomojiPanel!, replyPanel!] as [UIView] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                panel.topAnchor.constraint(equalTo: content.topAnchor),
                panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        headerRow = header
        // 双拼输入中：候选条盖在顶栏上
        let headerArea = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        pinyinPanel.candidateBar.translatesAutoresizingMaskIntoConstraints = false
        pinyinPanel.candidateBar.isHidden = true
        headerArea.addSubview(header)
        headerArea.addSubview(pinyinPanel.candidateBar)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerArea.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerArea.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerArea.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerArea.bottomAnchor),
            pinyinPanel.candidateBar.leadingAnchor.constraint(equalTo: headerArea.leadingAnchor),
            pinyinPanel.candidateBar.trailingAnchor.constraint(equalTo: headerArea.trailingAnchor),
            pinyinPanel.candidateBar.topAnchor.constraint(equalTo: headerArea.topAnchor),
            pinyinPanel.candidateBar.bottomAnchor.constraint(equalTo: headerArea.bottomAnchor),
        ])
        let root = UIStackView(arrangedSubviews: [headerArea, content])
        root.axis = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            headerArea.heightAnchor.constraint(equalToConstant: 36),
            segment.heightAnchor.constraint(equalToConstant: 34),
        ])

        // 右滑：语音 → 拼 → EN → 颜；左滑反向
        let right = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
        right.direction = .right
        let left = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
        left.direction = .left
        [right, left].forEach {
            $0.cancelsTouchesInView = false
            $0.delegate = self
            view.addGestureRecognizer($0)
        }
    }

    private func showMode(_ newMode: Mode, animated: Bool) {
        if mode == .pinyin, newMode != .pinyin { pinyinPanel?.reset() }
        mode = newMode
        TypefreeShared.defaults.set(newMode.rawValue, forKey: Self.modeKey)
        voicePanel.isHidden = newMode != .voice
        pinyinPanel.isHidden = newMode != .pinyin
        englishPanel.isHidden = newMode != .english
        kaomojiPanel.isHidden = newMode != .kaomoji
        replyPanel.isHidden = newMode != .reply
        heightConstraint.constant = newMode.height
        if newMode == .reply { loadClipboardForReply() }
        refreshLogo()
        for b in segmentButtons {
            // 英文页从双拼进，顶栏仍亮「拼」
            let on = b.tag == (newMode == .english ? Mode.pinyin : newMode).rawValue
            b.backgroundColor = on ? KTheme.raised : .clear
            b.setTitleColor(on ? KTheme.text : KTheme.secondary, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: on ? .semibold : .regular)
        }
        if animated {
            content.alpha = 0.4
            UIView.animate(withDuration: 0.15) { self.content.alpha = 1 }
        }
    }

    private func refreshReturnTitles() {
        voicePanel?.refreshReturnTitle()
        pinyinPanel?.refreshReturnTitle()
        englishPanel?.refreshReturnTitle()
        kaomojiPanel?.refreshReturnTitle()
        replyPanel?.refreshReturnTitle()
    }

    @objc private func segmentTapped(_ sender: UIButton) {
        guard let m = Mode(rawValue: sender.tag), m != mode else { return }
        haptic.impactOccurred()
        showMode(m, animated: true)
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        guard state != .recording else { return }
        let all = Mode.tabs
        let i = all.firstIndex(of: mode == .english ? .pinyin : mode) ?? 0
        let next = g.direction == .right ? min(i + 1, all.count - 1) : max(i - 1, 0)
        guard next != i else { return }
        haptic.impactOccurred()
        showMode(all[next], animated: true)
    }

    // MARK: - 风格

    /// 最近用过的语气排前面（按最近一次使用），没用过的保持默认顺序。只在键盘打开时排，用的时候不跳。
    private func orderedTones() -> [Tone] {
        let used = TypefreeShared.defaults.dictionary(forKey: Self.toneUsageKey) as? [String: Double] ?? [:]
        let defaultOrder = Tone.allCases.filter { !$0.isHidden }
        return defaultOrder.sorted { a, b in
            let ta = used[a.rawValue], tb = used[b.rawValue]
            switch (ta, tb) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return defaultOrder.firstIndex(of: a)! < defaultOrder.firstIndex(of: b)!
            }
        }
    }

    /// 语音页和回复页用同一份风格：一边改了另一边跟着变
    private func styleChanged(_ newStyle: StyleSelection, from page: Mode) {
        style = newStyle
        if page != .voice { voicePanel.setStyle(newStyle) }
        if page != .reply { replyPanel?.setStyle(newStyle) }
        if let data = try? JSONEncoder().encode(newStyle) {
            TypefreeShared.defaults.set(data, forKey: Self.styleKey)
        }
        render()
    }

    private func recordToneUsage() {
        guard !style.tones.isEmpty else { return }
        var used = TypefreeShared.defaults.dictionary(forKey: Self.toneUsageKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for tone in style.tones { used[tone.rawValue] = now }
        TypefreeShared.defaults.set(used, forKey: Self.toneUsageKey)
    }

    // MARK: - 渲染

    private func render() {
        guard let voicePanel else { return }
        if pendingPurpose == .intent, pendingSessionID != nil {
            switch state {
            case .recording, .waitingForApp: replyPanel.setPhase(.listening)
            case .processing: replyPanel.setPhase(.transcribing)
            default: break
            }
        }
        // 界面上看得见的状态（选了什么、在听、在整理）不再用文字重复，只留权限和出错
        switch state {
        case .idle:
            voicePanel.setMic(.idle)
            voicePanel.setMessage(hasFullAccess ? nil : "请在 设置 → 通用 → 键盘 → Typefree 里打开「允许完全访问」")
        case .waitingForApp, .recording:
            voicePanel.setMic(.recording)
            voicePanel.setMessage(nil)
        case .processing:
            voicePanel.setMic(.processing)
            voicePanel.setMessage(nil)
        case .message(let message):
            voicePanel.setMic(.idle)
            voicePanel.setMessage(message)
        }
        state == .recording ? startLevelLink() : stopLevelLink()
    }

    private func showMessage(_ message: String) {
        state = .message(message)
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, case .message = self.state else { return }
            self.state = .idle
        }
    }

    // MARK: - 麦克风

    private func micTapped() {
        haptic.impactOccurred()
        guard hasFullAccess else {
            showMessage("请先打开「允许完全访问」")
            return
        }
        switch state {
        case .recording:
            guard let sessionID = pendingSessionID else { state = .idle; return }
            sendCommand(.stop(sessionID: sessionID))
            state = .processing
        case .processing:
            return
        default:
            pendingPurpose = .dictation
            bridge.writeStyle(style)
            recordToneUsage()
            startRecording()
        }
    }

    /// 长按麦克风：开始听并弹出翻译目标。录音中按久了也当「说完了」
    private func micHoldBegan() -> Bool {
        switch state {
        case .recording:
            micTapped()
            return false
        case .processing:
            return false
        default:
            micTapped()
            return state == .recording   // 要跳主 App 时不弹目标
        }
    }

    /// 长按松手：落在英文 / 粤语上 = 这一句翻译；拖到麦克风下方 = 取消（结果丢掉、不进历史）
    private func micHoldEnded(_ end: VoicePanel.HoldEnd) {
        guard state == .recording, let sessionID = pendingSessionID else { return }
        haptic.impactOccurred()
        switch end {
        case .plain:
            break
        case .translate(let target):
            var once = style
            once.translate = target
            bridge.writeStyle(once)   // 主 App 在停止录音时才读风格
        case .cancel:
            bridge.writeStyle(StyleSelection(transient: true))
        }
        sendCommand(.stop(sessionID: sessionID))
        if end == .cancel {
            pendingSessionID = nil
            state = .idle
        } else {
            state = .processing
        }
    }

    private func startRecording() {
        let sessionID = UUID().uuidString
        pendingSessionID = sessionID
        if TypefreeShared.isStandbyAlive(bridge.readStandbyStatus()) {
            sendCommand(.start(sessionID: sessionID))
            state = .recording
            // 主 App 1.5 秒内没回「在录」，说明它其实已经不在了，改走跳转
            startConfirmTimer?.invalidate()
            startConfirmTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                guard let self, self.pendingSessionID == sessionID,
                      self.bridge.readSnapshot()?.sessionID != sessionID else { return }
                self.launchApp(sessionID: sessionID)
            }
        } else {
            launchApp(sessionID: sessionID)
        }
    }

    private func sendCommand(_ command: RecordingSessionCommand) {
        bridge.writeCommand(command)
        DarwinNotifier.shared.post(TypefreeShared.commandNotification)
    }

    private func launchApp(sessionID: String) {
        guard let url = URL(string: "\(TypefreeShared.urlScheme)://record?session=\(sessionID)") else { return }
        if openURLViaResponderChain(url) {
            leavingForApp = true
            state = .waitingForApp
        } else {
            showMessage("打不开 Typefree，请手动打开它一次")
        }
    }

    /// 键盘扩展不能直接调 UIApplication.open，顺着响应链找到宿主的 UIApplication 再调
    private func openURLViaResponderChain(_ url: URL) -> Bool {
        typealias OpenURL = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: NSClassFromString("UIApplication")!), current.responds(to: selector) {
                let imp = current.method(for: selector)
                let open = unsafeBitCast(imp, to: OpenURL.self)
                open(current, selector, url, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// 主 App 写了新快照：只认自己发起的那一次
    private func syncFromSnapshot() {
        guard let sessionID = pendingSessionID,
              let snapshot = bridge.readSnapshot(), snapshot.sessionID == sessionID else {
            if case .idle = state { render() }   // 待机状态可能变了，刷新提示
            return
        }
        switch snapshot.status {
        case .recording:
            startConfirmTimer?.invalidate()
            state = .recording
        case .processing:
            state = .processing
        case .done:
            pendingSessionID = nil
            guard lastInsertedSessionID != sessionID else { state = .idle; return }
            lastInsertedSessionID = sessionID
            let text = snapshot.text ?? ""
            if pendingPurpose == .intent {
                // 回复页说的想法：不上屏，记下来直接生成
                pendingPurpose = .dictation
                state = .idle
                replyIntent = text.isEmpty ? nil : text
                replyPanel.setIntent(replyIntent)
                generateReplies()
            } else {
                if !text.isEmpty {
                    lastInsertedText = text
                    textDocumentProxy.insertText(text)
                }
                state = .idle
            }
        case .error:
            pendingSessionID = nil
            if pendingPurpose == .intent {
                pendingPurpose = .dictation
                replyPanel.setPhase(.failed(snapshot.errorMessage ?? "没听清，再说一次"))
                state = .idle
            } else {
                showMessage(snapshot.errorMessage ?? "出错了，再试一次")
            }
        case .idle, .launching:
            break
        }
    }

    // MARK: - 回复

    /// 进回复页时读剪贴板；剪贴板没变过就不重读（避免反复弹「允许粘贴」）
    private func loadClipboardForReply() {
        let board = UIPasteboard.general
        guard hasFullAccess else {
            replyMessage = nil
            replyPanel.setPhase(.failed("请先打开「允许完全访问」"))
            return
        }
        if board.changeCount != lastClipboardChange {
            lastClipboardChange = board.changeCount
            let text = currentClipboard()
            // 自己刚从键盘打出去的字不算对方的消息
            let fresh = (text?.isEmpty == false && text != lastInsertedText) ? text : nil
            if fresh != replyMessage {
                replyMessage = fresh
                replyIntent = nil
                replyPanel.setIntent(nil)
                replyPanel.setPhase(fresh == nil ? .empty : .ready)
            }
        } else if replyMessage == nil {
            replyPanel.setPhase(.empty)
        }
        refreshLogo()
    }

    /// 剪贴板只在变过时读一次，免得反复弹「允许粘贴」
    private func currentClipboard() -> String? {
        let board = UIPasteboard.general
        if board.changeCount != clipboardCache.change {
            let text = board.hasStrings ? board.string?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            clipboardCache = (board.changeCount, text)
        }
        return clipboardCache.text
    }

    /// 回复页：顶栏左边显示对方的消息；其他页显示 Typefree 标志
    private func refreshLogo() {
        if mode == .reply, let message = replyMessage {
            let attachment = NSTextAttachment()
            attachment.image = KTheme.sfImage("arrowshape.turn.up.left", 12, weight: .semibold)?
                .withTintColor(KTheme.secondary, renderingMode: .alwaysOriginal)
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " " + message.replacingOccurrences(of: "\n", with: " "),
                                           attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: KTheme.text]))
            logoLabel.attributedText = text
        } else {
            logoLabel.attributedText = logoText
        }
    }

    private func generateReplies() {
        guard let message = replyMessage else {
            replyPanel.setPhase(.empty)
            return
        }
        replyPanel.setPhase(.generating)
        let requested = message
        ReplyGenerator.generate(message: message, intent: replyIntent, style: replyPanel.style) { [weak self] result in
            guard let self, self.replyMessage == requested else { return }
            switch result {
            case .success(let replies): self.replyPanel.setPhase(.results(replies))
            case .failure(let error): self.replyPanel.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    /// 回复页「说想法」：和语音页同一套录音，只是结果不上屏
    private func replyIntentTapped() {
        haptic.impactOccurred()
        guard hasFullAccess else { replyPanel.setPhase(.failed("请先打开「允许完全访问」")); return }
        if state == .recording, pendingPurpose == .intent, let sessionID = pendingSessionID {
            sendCommand(.stop(sessionID: sessionID))
            state = .processing
            return
        }
        guard state != .recording, state != .processing else { return }
        pendingPurpose = .intent
        bridge.writeStyle(StyleSelection(transient: true))
        startRecording()
    }

    // MARK: - 音量

    private func startLevelLink() {
        guard levelLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(updateLevel))
        link.preferredFramesPerSecond = 10
        link.add(to: .main, forMode: .common)
        levelLink = link
    }

    private func stopLevelLink() {
        levelLink?.invalidate()
        levelLink = nil
    }

    @objc private func updateLevel() {
        voicePanel.micButton.pushLevel(bridge.readAudioLevel())
    }
}

// 左右滑切页面：从可横滑的区域（候选条、语气、颜文字）或空格（长按移光标）开始的滑动不算
extension KeyboardViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let current = v, current !== view {
            if current is UIScrollView || current.accessibilityIdentifier == SpaceTrackpad.identifier { return false }
            v = current.superview
        }
        return true
    }
}
