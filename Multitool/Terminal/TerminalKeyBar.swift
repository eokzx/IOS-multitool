import UIKit

final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    enum Key {
        case ctrl
        case alt
        case raw(String)
        case text(String)
        case paste
        case hideKeyboard
        case snippets
    }

    var onKey: ((Key) -> Void)?
    private(set) var ctrlActive = false
    private(set) var altActive = false
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
    private var repeatTask: Task<Void, Never>?

    var enableInputClicksWhenVisible: Bool { true }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        autoresizingMask = [.flexibleWidth]
        build()
    }

    convenience init(width: CGFloat) {
        self.init(frame: CGRect(x: 0, y: 0, width: width, height: 46), inputViewStyle: .keyboard)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 46)
    }

    func setCtrl(_ active: Bool) {
        ctrlActive = active
        style(ctrlButton, active: active)
    }

    func setAlt(_ active: Bool) {
        altActive = active
        style(altButton, active: active)
    }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])

        stack.addArrangedSubview(makeButton(title: "esc") { [weak self] in self?.onKey?(.raw("\u{1b}")) })

        let ctrl = makeButton(title: "ctrl") { [weak self] in
            guard let self else { return }
            self.setCtrl(!self.ctrlActive)
        }
        ctrlButton = ctrl
        stack.addArrangedSubview(ctrl)

        let alt = makeButton(title: "alt") { [weak self] in
            guard let self else { return }
            self.setAlt(!self.altActive)
        }
        altButton = alt
        stack.addArrangedSubview(alt)

        stack.addArrangedSubview(makeButton(title: "tab") { [weak self] in self?.onKey?(.raw("\t")) })

        let arrows: [(String, String)] = [
            ("arrow.left", "\u{1b}[D"),
            ("arrow.down", "\u{1b}[B"),
            ("arrow.up", "\u{1b}[A"),
            ("arrow.right", "\u{1b}[C"),
        ]
        for (symbol, sequence) in arrows {
            stack.addArrangedSubview(makeButton(symbol: symbol, repeats: true) { [weak self] in self?.onKey?(.raw(sequence)) })
        }

        for character in ["|", "~", "/", "-", "_", ":", ";", "*", "&", "$", ">", "<", "`", "\\", "{", "}", "[", "]"] {
            stack.addArrangedSubview(makeButton(title: character) { [weak self] in self?.onKey?(.text(character)) })
        }

        let navigation: [(String, String)] = [
            ("home", "\u{1b}[H"),
            ("end", "\u{1b}[F"),
            ("pgup", "\u{1b}[5~"),
            ("pgdn", "\u{1b}[6~"),
        ]
        for (title, sequence) in navigation {
            stack.addArrangedSubview(makeButton(title: title) { [weak self] in self?.onKey?(.raw(sequence)) })
        }

        let functionKeys = ["\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS", "\u{1b}[15~", "\u{1b}[17~",
                            "\u{1b}[18~", "\u{1b}[19~", "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~"]
        for (index, sequence) in functionKeys.enumerated() {
            stack.addArrangedSubview(makeButton(title: "F\(index + 1)") { [weak self] in self?.onKey?(.raw(sequence)) })
        }

        stack.addArrangedSubview(makeButton(symbol: "doc.on.clipboard") { [weak self] in self?.onKey?(.paste) })
        stack.addArrangedSubview(makeButton(symbol: "text.badge.plus") { [weak self] in self?.onKey?(.snippets) })
        stack.addArrangedSubview(makeButton(symbol: "keyboard.chevron.compact.down") { [weak self] in self?.onKey?(.hideKeyboard) })
    }

    private static let keyBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.32, alpha: 1) : UIColor.white
    }

    private func makeButton(title: String? = nil, symbol: String? = nil, repeats: Bool = false, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = Self.keyBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let symbol {
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        }
        if let title {
            config.title = title
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
                return outgoing
            }
        }
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        if repeats {
            button.addAction(UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                action()
                self?.startRepeat(action)
            }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in
                self?.stopRepeat()
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        } else {
            button.addAction(UIAction { _ in
                UIDevice.current.playInputClick()
                action()
            }, for: .touchUpInside)
        }
        return button
    }

    private func style(_ button: UIButton?, active: Bool) {
        guard let button, var config = button.configuration else { return }
        config.baseBackgroundColor = active ? tintColor : Self.keyBackground
        config.baseForegroundColor = active ? .white : .label
        button.configuration = config
    }

    private func startRepeat(_ action: @escaping () -> Void) {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
