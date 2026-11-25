import UIKit

struct TerminalTheme: Identifiable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let selection: UInt32
    let ansi: [UInt32]
    let isDark: Bool

    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? all[0]
    }

    static let all: [TerminalTheme] = [
        TerminalTheme(
            id: "multitool", name: "Multitool Night",
            background: 0x0D1117, foreground: 0xE6EDF3, cursor: 0x2DD4BF, selection: 0x264F78,
            ansi: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
                   0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF],
            isDark: true
        ),
        TerminalTheme(
            id: "dracula", name: "Dracula",
            background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2, selection: 0x44475A,
            ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                   0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF],
            isDark: true
        ),
        TerminalTheme(
            id: "solarized-dark", name: "Solarized Dark",
            background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1, selection: 0x073642,
            ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                   0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3],
            isDark: true
        ),
        TerminalTheme(
            id: "nord", name: "Nord",
            background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xD8DEE9, selection: 0x434C5E,
            ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                   0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4],
            isDark: true
        ),
        TerminalTheme(
            id: "gruvbox", name: "Gruvbox Dark",
            background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2, selection: 0x504945,
            ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                   0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2],
            isDark: true
        ),
        TerminalTheme(
            id: "classic", name: "Klasyczny xterm",
            background: 0x000000, foreground: 0xE5E5E5, cursor: 0xE5E5E5, selection: 0x4D4D4D,
            ansi: [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                   0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF],
            isDark: true
        ),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light",
            background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75, selection: 0xEEE8D5,
            ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                   0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3],
            isDark: false
        ),
        TerminalTheme(
            id: "paper", name: "Papier",
            background: 0xFAFAFA, foreground: 0x383A42, cursor: 0x526FFF, selection: 0xE5E5E6,
            ansi: [0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0xA0A1A7,
                   0x696C77, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0xFAFAFA],
            isDark: false
        ),
    ]
}
