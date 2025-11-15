//
//  Environment+Device.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

import SwiftUI
#if os(iOS)
    import UIKit
#endif

// MARK: - DeviceIdiom

public enum DeviceIdiom: Equatable {
    case iPhone
    case iPad
    case Mac
}

// MARK: - Device

public enum Device {
    public static var idiom: DeviceIdiom {
        #if os(iOS)
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: return .iPhone
            case .pad: return .iPad
            default: return .iPhone
            }
        #elseif os(macOS)
            return .Mac
        #else
            return .mac
        #endif
    }

    public static var isPhone: Bool { idiom == .iPhone }
    public static var isPad: Bool { idiom == .iPad }
    public static var isMac: Bool { idiom == .Mac }
}

public extension EnvironmentValues {
    @Entry var deviceIdiom: DeviceIdiom = Device.idiom

    var isPhone: Bool { deviceIdiom == .iPhone }
    var isPad: Bool { deviceIdiom == .iPad }
    var isMac: Bool { deviceIdiom == .Mac }
}

public extension View {
    func deviceIdiom(_ idiom: DeviceIdiom) -> some View {
        environment(\.deviceIdiom, idiom)
    }
}
