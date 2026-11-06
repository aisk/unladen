// Protocol-translating gateway: ingress, routing, fallback, key pool, config.

import ArgumentParser
import Hummingbird
import UnladenAsyncHTTPClient
import UnladenCore

@main
struct UnladenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unladen",
        abstract: "A lightweight LLM protocol-translating gateway.",
    )

    func run() async throws {}
}
