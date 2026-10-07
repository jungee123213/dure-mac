import Foundation

/// 워크스페이스 하나가 쓰는 폴더와 문서 두 개. 설계문서 4절.
///
/// **조율자의 cwd 가 이 폴더다.** 그래서 조율자는 MCP 없이 두 문서를 그냥 파일로 읽는다.
///
/// 폴더 이름은 워크스페이스 **이름이 아니라 id** 다. 이름에는 공백·슬래시·한글이
/// 들어갈 수 있고 나중에 바뀔 수 있어서 경로로 쓸 수 없다.
/// **`nonisolated` 를 붙이지 않는다.** `GitReader` 와 다르다 — 저쪽은 블로킹 프로세스를
/// 메인 밖에서 돌려야 해서 필요했지만, 여기는 몇 KB 짜리 파일 쓰기라 메인에서 해도 된다.
/// 게다가 `HookBridge.home` 이 MainActor 라 `nonisolated` 로 만들면 참조에서 경고가 난다.
enum WorkspaceFolder {

    /// `root` 를 인자로 받는 이유는 테스트가 실제 `~/.dure` 를 건드리지 않기 위해서다.
    static var defaultRoot: URL {
        HookBridge.home.appendingPathComponent("workspaces", isDirectory: true)
    }

    static func url(for workspaceID: String, root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(workspaceID, isDirectory: true)
    }

    /// 앱이 자동 생성한다. 사람은 고치지 않는다.
    static func mapURL(for workspaceID: String, root: URL = defaultRoot) -> URL {
        url(for: workspaceID, root: root).appendingPathComponent("workspace.md")
    }

    /// 사람이 쓴다. 대시보드에서 편집한다.
    static func contextURL(for workspaceID: String, root: URL = defaultRoot) -> URL {
        url(for: workspaceID, root: root).appendingPathComponent("context.md")
    }

    /// 폴더를 만들고 `context.md` 가 없으면 씨앗을 넣는다.
    ///
    /// **이미 있으면 손대지 않는다.** 앱을 켤 때마다 불리는데 사람이 쓴 문서를
    /// 덮어쓰면 안 된다.
    static func ensure(_ workspaceID: String, root: URL = defaultRoot) throws {
        try FileManager.default.createDirectory(at: url(for: workspaceID, root: root),
                                                withIntermediateDirectories: true)
        let context = contextURL(for: workspaceID, root: root)
        guard !FileManager.default.fileExists(atPath: context.path) else { return }
        // 확인과 쓰기 사이에 누가 만들었으면 덮어쓰지 않고 실패한다.
        try Data(seedContext.utf8).write(to: context, options: .withoutOverwriting)
    }

    /// `context.md` 를 읽은 결과.
    ///
    /// 최종 리뷰 F6 — **없음과 못 읽음을 가른다.** 둘 다 빈 문자열로 돌려주면 편집창이
    /// 비어 보이고, 그대로 저장하면 사람이 쓴 문서가 지워진다. 이 파일은 다시 만들 수 없다 (D-26).
    /// `nonisolated` 인 이유 — 값 비교(`==`)가 메인액터에 묶이면 테스트에서 경고(Swift 6 에선 에러)가 난다.
    nonisolated enum ContextRead: Equatable {
        case text(String)
        /// 파일이 없다. 씨앗을 넣거나 빈 글로 시작해도 잃을 것이 없다.
        case missing
        /// 파일은 있는데 읽지 못했다(UTF-8 아님·권한·폴더 등). **이 위에는 쓰지 않는다.**
        case unreadable
    }

    /// 저장을 거부한 이유. 디스크가 읽어온 때와 다르면 덮어쓰지 않는다 (F2).
    nonisolated enum ContextConflict: Error, Equatable {
        case changedOutside
    }

    static func readContext(_ workspaceID: String, root: URL = defaultRoot) -> ContextRead {
        let url = contextURL(for: workspaceID, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unreadable }
        return .text(text)
    }

    /// `expecting` 은 편집을 시작할 때 읽은 결과다. **지금 디스크가 그것과 다르면 쓰지 않는다.**
    ///
    /// 최종 리뷰 F2 — 대시보드는 "Finder 에서 열기" 로 다른 편집기를 권하는데, 버퍼를 통째로
    /// 쓰면 그쪽에서 고친 글이 조용히 사라진다. 수정 시각이 아니라 **내용**을 비교한다 —
    /// `touch` 같은 것으로 시각만 바뀐 경우까지 충돌로 보지 않기 위해서다. 몇 KB 라 싸다.
    /// 못 읽은 파일(`.unreadable`)을 기대값으로 주면 항상 거부한다 (F6).
    ///
    /// 최종 리뷰 F5 — `.atomic` 으로 쓴다. 임시 파일에 쓰고 rename 하므로 쓰는 도중에
    /// 앱이 죽어도 사람이 쓴 문서가 잘린 채 남지 않는다.
    static func writeContext(_ workspaceID: String, _ text: String,
                             expecting base: ContextRead,
                             root: URL = defaultRoot) throws {
        guard base != .unreadable,
              readContext(workspaceID, root: root) == base
        else { throw ContextConflict.changedOutside }
        try Data(text.utf8).write(to: contextURL(for: workspaceID, root: root), options: .atomic)
    }

    /// 저장할 수 없는 편집 버퍼를 `context.md` 옆에 남긴다. 원본은 건드리지 않는다.
    ///
    /// 충돌(F2)이나 읽기 실패(F6) 상태에서 앱을 끄거나 워크스페이스를 바꾸면 버퍼가
    /// 사라진다. 그때 쓰는 마지막 안전망이다. 이름에 시각과 난수를 넣어 서로 덮어쓰지 않는다.
    /// `.withoutOverwriting` 은 `.atomic` 과 같이 쓸 수 없다. 새 파일이라 잘릴 원본이 없으므로 이쪽을 고른다.
    @discardableResult
    static func writeUnsavedCopy(_ workspaceID: String, _ text: String,
                                 root: URL = defaultRoot, now: Date = Date()) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        let copy = url(for: workspaceID, root: root)
            .appendingPathComponent("context.unsaved-\(stamp)-\(UUID().uuidString.prefix(4)).md")
        try Data(text.utf8).write(to: copy, options: .withoutOverwriting)
        return copy
    }

    /// 앱이 통째로 다시 만드는 파일이지만, 조율자가 반쯤 쓰인 지도를 읽지 않도록 원자적으로 쓴다.
    static func writeMap(_ workspaceID: String, _ text: String,
                         root: URL = defaultRoot) throws {
        try Data(text.utf8).write(to: mapURL(for: workspaceID, root: root), options: .atomic)
    }

    /// D-26 — 삭제한 워크스페이스의 폴더는 지우지 않고 **휴지통으로 보낸다.**
    /// `context.md` 는 사람이 쓴 문서라 실수했을 때 되살릴 길이 있어야 한다.
    ///
    /// `remover` 를 받는 이유는 테스트가 진짜 휴지통을 어지럽히지 않게 하기 위해서다.
    static func trash(_ workspaceID: String, root: URL = defaultRoot,
                      remover: (URL) throws -> Void = {
                          try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                      }) throws {
        let dir = url(for: workspaceID, root: root)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try remover(dir)
    }

    /// 빈 파일을 주면 뭘 써야 할지 모른다. 뼈대만 깔아준다.
    private static let seedContext = """
    # 공유 컨텍스트

    레포를 **가로지르는** 규약을 적는다. 레포 내부 규칙은 각 레포의 `CLAUDE.md` 에 있다.

    ## API 계약

    ## 네이밍 규약

    ## 도메인 용어

    ## 지금 하는 일

    """
}
