#if DEBUG
#if canImport(UIKit)
import DeviceKit

enum DeviceModel {
    static func marketingName() -> String {
        let device = Device.current
        if device.isSimulator {
            return device.safeDescription
        }
        return device.description
    }
}
#endif
#endif
