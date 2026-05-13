import Foundation
import Network
import OSLog

struct BondedRelayEndpoint: Equatable {
    let raw: String
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port

    static func parse(_ value: String?) -> BondedRelayEndpoint? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  components.scheme == "udp",
                  let host = components.host,
                  let portValue = components.port,
                  let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
                return nil
            }
            return BondedRelayEndpoint(
                raw: trimmed,
                host: NWEndpoint.Host(host),
                port: port)
        }

        guard let split = trimmed.lastIndex(of: ":") else { return nil }
        let hostPart = String(trimmed[..<split])
        let portPart = String(trimmed[trimmed.index(after: split)...])
        guard !hostPart.isEmpty,
              let portValue = UInt16(portPart),
              let port = NWEndpoint.Port(rawValue: portValue) else {
            return nil
        }
        return BondedRelayEndpoint(
            raw: "udp://\(hostPart):\(portValue)",
            host: NWEndpoint.Host(hostPart),
            port: port)
    }
}

final class BondedSocketPool {
    typealias InboundHandler = (Data) -> Void

    private struct LinkSocket {
        let interfaceName: String
        let connection: NWConnection
    }

    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "bonded-sockets")
    private let endpoint: BondedRelayEndpoint
    private let queue: DispatchQueue
    private let inbound: InboundHandler
    private var sockets: [String: LinkSocket] = [:]
    private var closed = false

    init(
        endpoint: BondedRelayEndpoint,
        queue: DispatchQueue,
        inbound: @escaping InboundHandler
    ) {
        self.endpoint = endpoint
        self.queue = queue
        self.inbound = inbound
    }

    func updateLinks(_ interfacesByLinkId: [String: NWInterface]) {
        guard !closed else { return }
        let validIds = Set(interfacesByLinkId.keys)
        for linkId in sockets.keys where !validIds.contains(linkId) {
            closeSocket(linkId: linkId)
        }

        for (linkId, interface) in interfacesByLinkId {
            if let existing = sockets[linkId],
               existing.interfaceName == interface.name {
                continue
            }
            closeSocket(linkId: linkId)
            openSocket(linkId: linkId, interface: interface)
        }
    }

    func send(linkId: String, bytes: Data) {
        guard !closed else { return }
        guard let socket = sockets[linkId] else {
            log.debug("no relay socket for link=\(linkId, privacy: .public)")
            return
        }
        socket.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log.debug("relay send failed link=\(linkId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        for linkId in Array(sockets.keys) {
            closeSocket(linkId: linkId)
        }
    }

    private func openSocket(linkId: String, interface: NWInterface) {
        let parameters = NWParameters.udp
        parameters.requiredInterface = interface
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(
            host: endpoint.host,
            port: endpoint.port,
            using: parameters)
        sockets[linkId] = LinkSocket(
            interfaceName: interface.name,
            connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("relay socket ready link=\(linkId, privacy: .public) iface=\(interface.name, privacy: .public) endpoint=\(self.endpoint.raw, privacy: .public)")
            case .failed(let error):
                self.log.warning("relay socket failed link=\(linkId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            case .waiting(let error):
                self.log.debug("relay socket waiting link=\(linkId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            case .cancelled:
                self.log.debug("relay socket cancelled link=\(linkId, privacy: .public)")
            default:
                break
            }
        }

        receiveLoop(linkId: linkId, connection: connection)
        connection.start(queue: queue)
    }

    private func receiveLoop(linkId: String, connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound(data)
            }
            if let error {
                self.log.debug("relay receive stopped link=\(linkId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                return
            }
            self.queue.async { [weak self] in
                guard let self,
                      !self.closed,
                      self.sockets[linkId]?.connection === connection else {
                    return
                }
                self.receiveLoop(linkId: linkId, connection: connection)
            }
        }
    }

    private func closeSocket(linkId: String) {
        guard let socket = sockets.removeValue(forKey: linkId) else { return }
        socket.connection.cancel()
    }
}
