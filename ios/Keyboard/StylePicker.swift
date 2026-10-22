import UIKit

/// 写法选择：左边语气网格（5 列、位置固定、可多选）| 右边程度（轻 / 中 / 重）和篇幅（精简 / 原样 / 扩充 / 梳理）两列单选。
/// 语音页常驻，回复页点「风格」展开；两页用同一份选择。
final class StylePicker: UIView {
    var onChange: ((StyleSelection) -> Void)?

    var style: StyleSelection { didSet { refresh() } }

    private let excluded: Set<Tone>
    private var chips: [Tone: ToneChip] = [:]
    private let intensityColumn = SegmentColumn(items: ToneIntensity.allCases.map(\.name), label: "程度")
    private let lengthColumn = SegmentColumn(items: ToneLength.allCases.map(\.name), label: "篇幅")

    /// excluding：这一页不适用的语气（回复页没有「点评」）
    init(style: StyleSelection, excluding: Set<Tone> = []) {
        self.style = style
        self.excluded = excluding
        super.init(frame: .zero)
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 9
        let tones = Tone.voiceGrid.filter { !excluded.contains($0) }
        stride(from: 0, to: tones.count, by: 5).forEach { start in
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .equalSpacing
            for i in start..<start + 5 {
                if i < tones.count {
                    let chip = ToneChip(tone: tones[i])
                    chip.addTarget(self, action: #selector(toneTapped(_:)), for: .touchUpInside)
                    chips[tones[i]] = chip
                    row.addArrangedSubview(chip)
                } else {
                    let spacer = UIView()
                    spacer.widthAnchor.constraint(equalToConstant: ToneChip.size).isActive = true
                    row.addArrangedSubview(spacer)
                }
            }
            grid.addArrangedSubview(row)
        }

        intensityColumn.onSelect = { [weak self] index in
            self?.update { $0.intensity = ToneIntensity.allCases[index] }
        }
        lengthColumn.onSelect = { [weak self] index in
            self?.update { $0.length = ToneLength.allCases[index] }
        }
        let columns = UIStackView(arrangedSubviews: [intensityColumn, lengthColumn])
        columns.axis = .horizontal
        columns.spacing = 6
        columns.distribution = .fillEqually

        [grid, columns].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: columns.leadingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: topAnchor),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor),
            columns.widthAnchor.constraint(equalToConstant: 118),
            columns.topAnchor.constraint(equalTo: topAnchor),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
        ])
    }

    private func refresh() {
        for (tone, chip) in chips { chip.isOn = style.tones.contains(tone) }
        intensityColumn.selectedIndex = ToneIntensity.allCases.firstIndex(of: style.intensity) ?? 1
        lengthColumn.selectedIndex = ToneLength.allCases.firstIndex(of: style.length) ?? 1
        // 程度只作用于语气：没选语气时变暗；点评是整套写法，程度和篇幅都不生效
        let reviewing = style.tones.contains(.review)
        intensityColumn.isActive = !style.tones.isEmpty && !reviewing
        lengthColumn.isActive = !reviewing
    }

    private func update(_ change: (inout StyleSelection) -> Void) {
        change(&style)
        onChange?(style)
    }

    @objc private func toneTapped(_ chip: ToneChip) {
        update { $0.toggle(chip.tone) }
    }
}
