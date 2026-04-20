import Foundation
import Network
import InspectCore

final class InspectBrowser {
    var onChange: (([InspectEndpoint]) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "swift-inspector.browser")

    func start() {
        stop()
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: InspectProtocol.bonjourServiceType,
            domain: nil
        )
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.compactMap { result -> InspectEndpoint? in
                guard case let .service(name, _, _, _) = result.endpoint else {
                    return nil
                }
                return InspectEndpoint(
                    id: name,
                    name: name,
                    endpoint: result.endpoint
                )
            }
            self?.onChange?(endpoints)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
