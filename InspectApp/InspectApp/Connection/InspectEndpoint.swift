import Foundation
import Network

struct InspectEndpoint: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    var isConnected: Bool

    init(id: String, name: String, endpoint: NWEndpoint, isConnected: Bool = false) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.isConnected = isConnected
    }
}
