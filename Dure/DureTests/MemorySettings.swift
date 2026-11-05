// Dure/DureTests/MemorySettings.swift
import Foundation
@testable import Dure

/// 테스트용 설정 저장소 — 메모리에만 둔다. 이슈 #29: `UserDefaults(suiteName:)` 는 지워도 cfprefsd 가
/// `~/Library/Preferences` 에 빈 plist 를 비동기로 다시 써서 테스트마다 파일이 쌓였다(정리 전 252개).
final class MemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
}
