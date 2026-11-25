import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Citadel

final class LocalPortForwarder {
    let rule: PortForwardRule
    private var serverChannel: Channel?

    init(rule: PortForwardRule) {
        self.rule = rule
    }

    func start(using client: SSHClient) async throws {
        let rule = self.rule
        let bootstrap = ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { inbound in
                let (localGlue, remoteGlue) = ForwardGlueHandler.matchedPair()
                do {
                    try inbound.pipeline.syncOperations.addHandler(localGlue)
                } catch {
                    return inbound.eventLoop.makeFailedFuture(error)
                }
                let promise = inbound.eventLoop.makePromise(of: Void.self)
                promise.completeWithTask {
                    let origin = try inbound.remoteAddress ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
                    _ = try await client.createDirectTCPIPChannel(
                        using: SSHChannelType.DirectTCPIP(
                            targetHost: rule.remoteHost,
                            targetPort: rule.remotePort,
                            originatorAddress: origin
                        )
                    ) { channel in
                        do {
                            try channel.pipeline.syncOperations.addHandler(remoteGlue)
                            return channel.eventLoop.makeSucceededVoidFuture()
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }
                }
                return promise.futureResult
            }
        serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: rule.localPort).get()
    }

    func stop() {
        serverChannel?.close(promise: nil)
        serverChannel = nil
    }
}

final class ForwardGlueHandler {
    private var partner: ForwardGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (ForwardGlueHandler, ForwardGlueHandler) {
        let first = ForwardGlueHandler()
        let second = ForwardGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension ForwardGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, case .inputClosed = channelEvent {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
