// Dure/Dure/TestHost.swift
import Foundation

/// 유닛 테스트 호스트로 떠 있나. 이슈 #29.
nonisolated enum TestHost {
    static func isActive(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
    static var isActive: Bool { isActive(ProcessInfo.processInfo.environment) }
}
