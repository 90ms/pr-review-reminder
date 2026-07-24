import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

@MainActor
public protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
public final class LaunchAtLoginService: LaunchAtLoginManaging {
    public init() {}

    public var isEnabled: Bool {
        #if canImport(ServiceManagement)
        SMAppService.mainApp.status == .enabled
        #else
        false
        #endif
    }

    public func setEnabled(_ enabled: Bool) throws {
        #if canImport(ServiceManagement)
        if enabled, !isEnabled {
            try SMAppService.mainApp.register()
        } else if !enabled, isEnabled {
            try SMAppService.mainApp.unregister()
        }
        #endif
    }
}
