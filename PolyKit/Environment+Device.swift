//
//  Environment+Device.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if canImport(SwiftUI)
    import SwiftUI
    #if os(iOS)
        import UIKit
    #endif

    // MARK: - DeviceIdiom

    public enum DeviceIdiom: Equatable {
        case iPhone
        case iPad
        case Mac
        case Watch
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
            #elseif os(watchOS)
                return .Watch
            #else
                return .Mac
            #endif
        }

        public static var isPhone: Bool { idiom == .iPhone }
        public static var isPad: Bool { idiom == .iPad }
        public static var isMac: Bool { idiom == .Mac }
        public static var isWatch: Bool { idiom == .Watch }
    }

    public extension EnvironmentValues {
        @Entry var deviceIdiom: DeviceIdiom = Device.idiom

        var isPhone: Bool { self.deviceIdiom == .iPhone }
        var isPad: Bool { self.deviceIdiom == .iPad }
        var isMac: Bool { self.deviceIdiom == .Mac }
        var isWatch: Bool { self.deviceIdiom == .Watch }
    }

    public extension View {
        func deviceIdiom(_ idiom: DeviceIdiom) -> some View {
            environment(\.deviceIdiom, idiom)
        }
    }
#endif
