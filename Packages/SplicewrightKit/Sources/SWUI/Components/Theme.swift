import SwiftUI

/// Premiere-style dark palette. The workspace always renders dark, like most NLEs,
/// so footage is judged against a neutral surround.
enum Theme {
    static let windowBackground = Color(white: 0.11)
    static let panelBackground = Color(white: 0.14)
    static let panelHeader = Color(white: 0.17)
    static let divider = Color(white: 0.06)
    static let textPrimary = Color(white: 0.86)
    static let textSecondary = Color(white: 0.56)
    static let accent = Color(red: 0.18, green: 0.55, blue: 0.92)
    static let activeOutline = Color(red: 0.18, green: 0.55, blue: 0.92)
    static let timecode = Color(red: 0.29, green: 0.64, blue: 1.0)
    static let markedRange = Color(white: 1, opacity: 0.12)
    static let playhead = Color(red: 0.29, green: 0.64, blue: 1.0)
    static let videoTrack = Color(red: 0.36, green: 0.42, blue: 0.62)
    static let audioTrack = Color(red: 0.29, green: 0.52, blue: 0.40)
    static let titleClip = Color(red: 0.55, green: 0.38, blue: 0.68)
    static let offline = Color(red: 0.85, green: 0.25, blue: 0.25)
    static let waveform = Color(red: 0.36, green: 0.78, blue: 0.55)

    static let timecodeFont = Font.system(size: 15, weight: .regular, design: .monospaced)
    static let smallTimecodeFont = Font.system(size: 11, weight: .regular, design: .monospaced)
}
