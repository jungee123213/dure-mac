import Foundation

/// 한 레포의 git 상태. F8 — **읽기만 한다** (ADR-4).
/// 페인 헤더에 브랜치명과 변경 파일 수를 띄우는 것이 전부다.
nonisolated struct GitStatus: Equatable, Sendable {
    var branch: String
    /// `git status --porcelain` 의 줄 수. untracked 를 포함한다 (D-14).
    var dirtyCount: Int
    /// `rev-parse --abbrev-ref` 가 "HEAD" 를 준 경우. 브랜치 위가 아니다.
    var isDetached: Bool
    /// `git log --oneline -5`. 조율자가 "남이 뭘 바꿨나" 를 읽는 값이다 (설계문서 4절).
    var recentCommits: [String] = []

    var isClean: Bool { dirtyCount == 0 }
}

/// git 출력 두 줄기를 `GitStatus` 로 바꾼다.
/// **순수 함수만 둔다** — 프로세스 실행 없이 출력 형태를 테스트하기 위해서다
/// (`TranscriptParser` 와 같은 이유).
nonisolated enum GitStatusParser {

    static func parse(branch: String, porcelain: String, log: String = "") -> GitStatus {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        // `split` 은 기본적으로 빈 조각을 버린다. 줄 끝 개행이 한 줄로 세어지지 않는다.
        let count = porcelain.split(separator: "\n").count
        let commits = log.split(separator: "\n").map(String.init)
        return GitStatus(branch: name, dirtyCount: count,
                         isDetached: name == "HEAD", recentCommits: commits)
    }
}

/// 레포별 마지막으로 읽은 git 상태.
///
/// **`nil` 을 덮어쓰지 않는 것이 이 타입의 존재 이유다** (D-13).
/// 읽기가 실패했을 때 값을 지우면 화면이 `clean` 으로 보이는데, 그것은
/// "변경이 없다" 가 아니라 "모른다" 이므로 거짓말이 된다.
struct GitStatusCache {
    private var byRepo: [String: GitStatus] = [:]

    subscript(repoID: String) -> GitStatus? { byRepo[repoID] }

    /// `fresh` 가 nil 이면 아무것도 하지 않는다.
    mutating func update(_ repoID: String, with fresh: GitStatus?) {
        guard let fresh else { return }
        byRepo[repoID] = fresh
    }
}
