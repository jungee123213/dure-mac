// Dure/DureTests/FakeRunner.swift
import Foundation
@testable import Dure

final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let respond: @Sendable (String) -> CommandResult

    init(respond: @escaping @Sendable (String) -> CommandResult) { self.respond = respond }

    func run(_ script: String, timeout: TimeInterval) async -> CommandResult {
        lock.withLock { log.append(script) }
        return respond(script)
    }

    var scripts: [String] { lock.withLock { log } }

    static func ok(_ s: String) -> CommandResult { CommandResult(status: 0, stdout: Data(s.utf8), stderr: Data(), timedOut: false) }
}
