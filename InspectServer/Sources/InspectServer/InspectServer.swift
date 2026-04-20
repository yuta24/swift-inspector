#if DEBUG
import Foundation

public enum InspectServer {
    private static var listener: InspectListener?

    public static func start(serviceName: String? = nil) {
        if listener != nil { return }
        let instance = InspectListener(serviceName: serviceName)
        do {
            try instance.start()
            listener = instance
        } catch {
            assertionFailure("InspectServer failed to start: \(error)")
        }
    }

    public static func stop() {
        listener?.stop()
        listener = nil
    }
}
#endif
