import Foundation

/// 이슈 #38 — 마지막에 보던 워크스페이스. 앱을 다시 켜면 이걸 연다.
/// 화면 상태라 DB 가 아니라 설정에 둔다. 페인은 기억하지 않는다 — 다시 켜면 전부 시작 안 한 상태다.
nonisolated enum LastWorkspace {
    static let key = "lastWorkspaceID"

    /// 저장된 워크스페이스가 아직 있으면 그것, 없으면(삭제됨 · 처음 실행) 첫 번째.
    static func pick(saved: String?, available: [String]) -> String? {
        if let saved, available.contains(saved) { return saved }
        return available.first
    }

    static func saved(in settings: SettingsStore) -> String? {
        settings.object(forKey: key) as? String
    }

    /// nil 은 무시한다. 삭제 직후 선택이 잠깐 비는데, 곧 `load()` 가 고른 워크스페이스로 덮어쓴다.
    static func remember(_ id: String?, in settings: SettingsStore) {
        guard let id else { return }
        settings.set(id, forKey: key)
    }
}
