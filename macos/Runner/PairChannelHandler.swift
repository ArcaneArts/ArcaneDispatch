//
//  PairChannelHandler.swift
//
//  Glue between the Dart `dispatch_pair` MethodChannel and the Swift
//  `PairedNetworkService`. Mirrors `TunnelManager`'s style.
//

import Cocoa
import FlutterMacOS
import Foundation

@available(macOS 10.15, *)
public final class PairChannelHandler: NSObject, FlutterStreamHandler {
    public static let shared = PairChannelHandler()
    private let service = PairedNetworkService()
    private var eventSink: FlutterEventSink?

    private override init() {
        super.init()
    }

    public func register(with controller: FlutterViewController) {
        let methodChannel = FlutterMethodChannel(
            name: "dispatch_pair",
            binaryMessenger: controller.engine.binaryMessenger
        )
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        let eventChannel = FlutterEventChannel(
            name: "dispatch_pair/events",
            binaryMessenger: controller.engine.binaryMessenger
        )
        eventChannel.setStreamHandler(self)
    }

    // MARK: - Method handlers

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "publish":
            guard let args = call.arguments as? [String: Any],
                  let snapshot = snapshotFromArgs(args) else {
                result(FlutterError(code: "bad_args",
                                    message: "publish requires a beacon payload",
                                    details: nil))
                return
            }
            let ok = service.publish(snapshot)
            result(ok)
        case "unpublish":
            service.unpublish()
            result(nil)
        case "startBrowse":
            service.startBrowsing { [weak self] event in
                self?.forward(event)
            }
            result(nil)
        case "stopBrowse":
            service.stopBrowsing()
            result(nil)
        case "snapshot":
            let peers = service.snapshot.map { encodeSnapshot($0) }
            result(peers)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func snapshotFromArgs(_ args: [String: Any]) -> PairedNetworkService.PeerSnapshot? {
        guard let deviceId = args["deviceId"] as? String,
              let deviceName = args["deviceName"] as? String,
              let fingerprint = args["fingerprint"] as? String else {
            return nil
        }
        let host = args["host"] as? String ?? ""
        let port = (args["port"] as? Int) ?? 44430
        let version = args["version"] as? String ?? "1"
        return PairedNetworkService.PeerSnapshot(
            deviceId: deviceId,
            deviceName: deviceName,
            host: host,
            port: port,
            fingerprint: fingerprint,
            version: version
        )
    }

    private func encodeSnapshot(_ p: PairedNetworkService.PeerSnapshot)
        -> [String: Any]
    {
        return [
            "deviceId": p.deviceId,
            "deviceName": p.deviceName,
            "host": p.host,
            "port": p.port,
            "fingerprint": p.fingerprint,
            "version": p.version,
        ]
    }

    private func forward(_ event: PairedNetworkService.PeerEvent) {
        guard let sink = eventSink else { return }
        let kind: String = (event.kind == .found) ? "found" : "lost"
        let payload: [String: Any] = [
            "kind": kind,
            "beacon": encodeSnapshot(event.peer),
        ]
        DispatchQueue.main.async { sink(payload) }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments _: Any?,
                         eventSink events: @escaping FlutterEventSink)
        -> FlutterError?
    {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments _: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
