import SwiftUI

/// Dark panel, lime accent, white titles, grey secondary text, one colour per "buddy" (SPEC §9).
enum Theme {
    static let panel = Color(red: 0.086, green: 0.090, blue: 0.098)
    static let card = Color(red: 0.137, green: 0.141, blue: 0.153)
    static let cardRaised = Color(red: 0.188, green: 0.192, blue: 0.208)
    static let terminal = Color(red: 0.063, green: 0.067, blue: 0.075)
    static let lime = Color(red: 0.776, green: 0.945, blue: 0.208)
    static let grey = Color(white: 0.62)
    static let dim = Color(white: 0.38)
    static let red = Color(red: 0.93, green: 0.27, blue: 0.27)
    static let buddies: [Color] = [
        Color(red: 0.231, green: 0.510, blue: 0.965),   // blue
        Color(red: 0.941, green: 0.325, blue: 0.608),   // pink
        Color(red: 0.961, green: 0.620, blue: 0.259),   // orange
        Color(red: 0.545, green: 0.361, blue: 0.965),   // purple
        Color(red: 0.176, green: 0.831, blue: 0.749),   // teal
        Color(red: 0.980, green: 0.800, blue: 0.082),   // yellow
    ]
    static func buddy(_ i: Int) -> Color { buddies[i % buddies.count] }
    static let width: CGFloat = 400
}
