//
//  PolyText.swift
//  polykit-swift
//
//  Created by Danny Stewart on 9/26/25.
//

public struct Text {
    public static func color(_ text: String, _ color: TextColor) -> String {
        return "\(color.rawValue)\(text)\(TextColor.reset.rawValue)"
    }

    public static func printColor(_ text: String, _ color: TextColor, terminator: String = "\n") {
        print(Text.color(text, color), terminator: terminator)
    }
}
