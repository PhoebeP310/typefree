import UIKit

/// 颜文字页：分类横滑 · 三列网格竖滑 · 底栏。点一下上屏并记进「最近」。
final class KaomojiPanel: UIView {
    private static let recentKey = "keyboard_recent_kaomoji"

    private static let catalog: [(String, [String])] = [
        ("开心", ["(≧▽≦)", "(๑˃ᴗ˂)ﻭ", "ヽ(✿ﾟ▽ﾟ)ノ", "(*^▽^*)", "٩(ˊᗜˋ*)و", "(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧", "o(*￣▽￣*)ブ", "(￣▽￣)~*", "♪(´▽｀)", "(＾▽＾)", "ヾ(≧▽≦*)o", "(o゜▽゜)o☆", "(〃'▽'〃)", "ヽ(°〇°)ﾉ", "(*≧ω≦)", "＼(^o^)／", "(๑•̀ㅂ•́)و✧", "(^_^)v"]),
        ("喜欢", ["(♡˙︶˙♡)", "(づ￣ ³￣)づ", "(｡♥‿♥｡)", "(*/ω＼*)", "(灬º‿º灬)♡", "ヾ(❀╹◡╹)ﾉ~", "(´∀｀)♡", "(っ´▽`)っ", "(ღ˘⌣˘ღ)", "♡(ӦｖӦ｡)", "(｡･ω･｡)ﾉ♡", "(*˘︶˘*).｡.:*♡", "(●'◡'●)ﾉ♥", "(≧◡≦) ♡", "( ˘ ³˘)♥"]),
        ("卖萌", ["(｡･ω･｡)", "(๑´ڡ`๑)", "(｡•́︿•̀｡)", "(*´ω`*)", "(=^･ω･^=)", "ʕ•ᴥ•ʔ", "(●´ω｀●)", "(´・ω・`)", "(◕ᴗ◕✿)", "(๑• . •๑)", "(ꈍᴗꈍ)", "(｀・ω・´)", "(｡>﹏<｡)", "(o´ω`o)ﾉ", "(๑´ㅂ`๑)"]),
        ("无奈", ["┐(´д`)┌", "¯\\_(ツ)_/¯", "(－‸ლ)", "(￣ー￣;)", "(´-ω-`)", "(；一_一)", "_(:з」∠)_", "(￣～￣;)", "(⊙_⊙;)", "(ーー;)", "(；´д｀)ゞ", "(´ε｀；)", "(╯_╰)", "(´ーωー`)", "（ ´_ゝ`）"]),
        ("生气", ["(╬ Ò﹏Ó)", "(ノ｀Д)ノ", "(╯°□°)╯︵ ┻━┻", "(｀皿´)", "(╬￣皿￣)", "ヽ(#`Д´)ﾉ", "(¬_¬)", "(￣^￣)", "(｀へ´)", "(#｀-_ゝ-)", "(ꐦ°᷄д°᷅)", "(•̀へ •́ ╮ )", "凸(｀⌒´メ)凸", "(￣ε(#￣)", "(｀Д´)"]),
        ("动作", ["(｡･∀･)ﾉﾞ", "( ´ ▽ ` )ﾉ", "(￣ω￣;)", "ε=ε=┌( >_<)┘", "(っ˘ω˘ς )", "( ˘ᵕ˘ )zzZ", "(　´∀｀)σ", "(ง •̀_•́)ง", "(＾Ｕ＾)ノ~ＹＯ", "m(_ _)m", "(*￣3￣)╭", "(っ °Д °;)っ", "ヾ(･ω･*)ﾉ", "(ﾉ´▽｀)ﾉ♪", "(`･ω･´)ゞ"]),
    ]

    private let actions: KeyboardActions
    private var categoryButtons: [UIButton] = []
    private var selected = 1
    private let gridScroll = UIScrollView()
    private let gridStack = UIStackView()
    private let returnButton = KeyButton(title: "发送", style: .function, fontSize: 15)
    private lazy var deleter = DeleteRepeater { [weak self] in self?.actions.deleteBackward() }
    private lazy var trackpad = SpaceTrackpad(move: actions.moveCursor)

    init(actions: KeyboardActions) {
        self.actions = actions
        super.init(frame: .zero)
        if !Self.recent.isEmpty { selected = 0 }
        build()
        showCategory(selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshReturnTitle() { returnButton.setTitle(actions.returnTitle(), for: .normal) }

    private static var recent: [String] {
        get { TypefreeShared.defaults.stringArray(forKey: recentKey) ?? [] }
        set { TypefreeShared.defaults.set(Array(newValue.prefix(24)), forKey: recentKey) }
    }

    private func items(for index: Int) -> [String] {
        index == 0 ? Self.recent : Self.catalog[index - 1].1
    }

    private func build() {
        let names = ["最近"] + Self.catalog.map(\.0)
        let tabs = UIStackView()
        tabs.axis = .horizontal
        tabs.spacing = 2
        for (i, name) in names.enumerated() {
            let b = UIButton(type: .custom)
            b.setTitle(name, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            b.layer.cornerRadius = 15
            b.tag = i
            b.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            categoryButtons.append(b)
            tabs.addArrangedSubview(b)
        }
        let tabScroll = UIScrollView()
        tabScroll.showsHorizontalScrollIndicator = false
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: tabScroll.contentLayoutGuide.bottomAnchor),
            tabs.heightAnchor.constraint(equalTo: tabScroll.frameLayoutGuide.heightAnchor),
        ])

        gridScroll.showsVerticalScrollIndicator = false
        gridStack.axis = .vertical
        gridStack.spacing = 6
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridScroll.addSubview(gridStack)
        NSLayoutConstraint.activate([
            gridStack.leadingAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.trailingAnchor),
            gridStack.topAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.topAnchor),
            gridStack.bottomAnchor.constraint(equalTo: gridScroll.contentLayoutGuide.bottomAnchor),
            gridStack.widthAnchor.constraint(equalTo: gridScroll.frameLayoutGuide.widthAnchor),
        ])

        let globe = KeyButton(image: "globe", style: .function)
        actions.attachGlobe(globe)
        let space = KeyButton(title: "空格", style: .function, fontSize: 15)
        trackpad.attach(to: space)
        space.setTitleColor(KTheme.secondary, for: .normal)
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        let delete = KeyButton(image: "delete.left", style: .function)
        deleter.attach(to: delete)
        returnButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        refreshReturnTitle()
        let bottom = UIStackView(arrangedSubviews: [globe, space, delete, returnButton])
        bottom.axis = .horizontal
        bottom.spacing = 6

        let root = UIStackView(arrangedSubviews: [tabScroll, gridScroll, bottom])
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 30),
            bottom.heightAnchor.constraint(equalToConstant: 44),
            globe.widthAnchor.constraint(equalToConstant: 44),
            delete.widthAnchor.constraint(equalToConstant: 52),
            returnButton.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    private func showCategory(_ index: Int) {
        selected = index
        for b in categoryButtons {
            let on = b.tag == index
            b.backgroundColor = on ? KTheme.raised : .clear
            b.setTitleColor(on ? KTheme.text : KTheme.secondary, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: on ? .semibold : .regular)
        }
        gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let list = items(for: index)
        if list.isEmpty {
            let empty = UILabel()
            empty.text = "还没有用过的颜文字"
            empty.font = .systemFont(ofSize: 14)
            empty.textColor = KTheme.secondary
            empty.textAlignment = .center
            empty.heightAnchor.constraint(equalToConstant: 80).isActive = true
            gridStack.addArrangedSubview(empty)
        }
        stride(from: 0, to: list.count, by: 3).forEach { start in
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 6
            row.distribution = .fillEqually
            for i in start..<start + 3 {
                if i < list.count {
                    let b = KeyButton(title: list[i], style: .function, fontSize: 14)
                    b.titleLabel?.adjustsFontSizeToFitWidth = true
                    b.titleLabel?.minimumScaleFactor = 0.6
                    b.titleLabel?.lineBreakMode = .byClipping
                    b.addTarget(self, action: #selector(kaomojiTapped(_:)), for: .touchUpInside)
                    row.addArrangedSubview(b)
                } else {
                    row.addArrangedSubview(UIView())
                }
            }
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            gridStack.addArrangedSubview(row)
        }
        gridScroll.setContentOffset(.zero, animated: false)
    }

    @objc private func categoryTapped(_ sender: UIButton) { showCategory(sender.tag) }

    @objc private func kaomojiTapped(_ sender: UIButton) {
        guard let k = sender.title(for: .normal) else { return }
        actions.insert(k)
        var r = Self.recent
        r.removeAll { $0 == k }
        r.insert(k, at: 0)
        Self.recent = r
    }

    @objc private func spaceTapped() { actions.insert(" ") }
    @objc private func returnTapped() { actions.returnKey() }
}
