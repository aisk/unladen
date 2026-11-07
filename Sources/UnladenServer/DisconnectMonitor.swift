// Client-disconnect detection.
//
// Hummingbird 2 does not cancel a route handler when its client goes away:
// a handler waiting for an upstream (before its response head) or writing a
// quiet stream keeps running, and so does the upstream request. The
// gateway therefore watches the connection itself: a handler placed first
// in the channel pipeline sees the client's half-close (`inputClosed`; the
// server enables remote half-closure, and Hummingbird keeps reading the
// connection while the request body has been consumed) and the connection
// closing (`channelInactive`), and tells a `DisconnectMonitor`, which
// cancels the work registered with it.
//
// A half-close counts as a disconnect, on purpose: it is the only signal a
// client that gave up before the response head sends (curl ^C, an HTTP
// client timing out), and reacting to it is what cancels the upstream
// request then. The cost: a client that half-closes its side after sending
// the request but still waits for the response (`shutdown(SHUT_WR)`, rare
// for HTTP clients) has its request cancelled. `unladen --help` says so.

import NIOConcurrencyHelpers
import NIOCore

/// Watches one request's connection and cancels registered work when the
/// client disconnects.
final class DisconnectMonitor: Sendable {
    private struct State {
        var disconnected = false
        var nextID = 0
        var callbacks: [Int: @Sendable () -> Void] = [:]
    }

    private let state = NIOLockedValueBox(State())
    private let handler: DisconnectHandler?
    private let channel: (any Channel)?

    /// A monitor that never fires (no connection to watch).
    init() {
        channel = nil
        handler = nil
    }

    private init(channel: any Channel, handler: DisconnectHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Installs a watcher on `channel` for the rest of the request; call
    /// ``uninstall()`` when the response is complete.
    static func install(on channel: any Channel) async -> DisconnectMonitor {
        let handler = DisconnectHandler()
        let monitor = DisconnectMonitor(channel: channel, handler: handler)
        do {
            try await channel.eventLoop.submit {
                handler.monitor = monitor
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            }.get()
        } catch {
            // The pipeline is gone: the connection already closed.
            monitor.fire()
        }
        return monitor
    }

    /// Removes the watcher from the connection (it may serve more requests).
    func uninstall() {
        state.withLockedValue { $0.callbacks = [:] }
        guard let channel, let handler else { return }
        channel.eventLoop.execute {
            handler.monitor = nil
            _ = channel.pipeline.syncOperations.removeHandler(handler)
        }
    }

    var isDisconnected: Bool { state.withLockedValue { $0.disconnected } }

    /// Calls `callback` once when the client disconnects (at once if it
    /// already has). Returns a token for ``remove(_:)``.
    @discardableResult
    func onDisconnect(_ callback: @escaping @Sendable () -> Void) -> Int {
        let id: Int? = state.withLockedValue { state in
            guard !state.disconnected else { return nil }
            defer { state.nextID += 1 }
            state.callbacks[state.nextID] = callback
            return state.nextID
        }
        guard let id else {
            callback()
            return -1
        }
        return id
    }

    func remove(_ id: Int) {
        _ = state.withLockedValue { $0.callbacks.removeValue(forKey: id) }
    }

    /// Marks the client gone and runs the callbacks.
    func fire() {
        let callbacks = state.withLockedValue { state -> [@Sendable () -> Void] in
            guard !state.disconnected else { return [] }
            state.disconnected = true
            defer { state.callbacks = [:] }
            return Array(state.callbacks.values)
        }
        for callback in callbacks { callback() }
    }

    /// Runs `operation` in a task that is cancelled when the client
    /// disconnects or the caller is cancelled.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        let id = onDisconnect { task.cancel() }
        defer { remove(id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// The pipeline handler behind ``DisconnectMonitor``; passes everything on.
/// Its state is only touched on the channel's event loop.
final class DisconnectHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny

    /// Event-loop confined.
    weak var monitor: DisconnectMonitor?

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The client's half-close (end of its input) is treated as a
        // disconnect: see the note at the top of the file.
        if let event = event as? ChannelEvent, event == .inputClosed {
            monitor?.fire()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        monitor?.fire()
        context.fireChannelInactive()
    }
}
