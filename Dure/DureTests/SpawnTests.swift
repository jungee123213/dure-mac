import Foundation
import Testing
@testable import Dure

/// Step 7 · F10a 실행 시점 브로드캐스트.
/// 설계문서 184줄 — `claude "<prompt>"` 인자로 넘긴다.
///
/// **여기서 지키려는 것은 이스케이프다.** 프롬프트는 사람이 자유롭게 쓰는 문장이라
/// 따옴표·백틱·`$`·줄바꿈이 다 들어온다. `zsh -ilc` 로 넘어가는 문자열 안에 박히므로
/// 한 글자만 새도 명령이 쪼개지거나 셸이 엉뚱한 것을 실행한다.
struct SpawnTests {

    static func script(_ prompt: String?) -> String {
        Spawn.script(repoPath: "/repo", sessionID: "pane-1", model: nil, initialPrompt: prompt)
    }

    // MARK: - 붙이는가

    @Test func 프롬프트를_claude_인자로_붙인다() {
        #expect(Self.script("README 를 먼저 읽어라").hasSuffix("'README 를 먼저 읽어라'"))
    }

    @Test func 프롬프트가_없으면_인자를_붙이지_않는다() {
        let bare = Self.script(nil)
        #expect(bare.hasSuffix("hooks.json'") || bare.hasSuffix(".json'"))
        #expect(!bare.contains("''"))
    }

    /// 빈 칸으로 시작하는 날이 더 많다. nil 과 똑같이 굴어야 한다.
    @Test func 빈_문자열은_없는_것과_같다() {
        #expect(Self.script("") == Self.script(nil))
    }

    @Test func 공백뿐인_프롬프트도_없는_것과_같다() {
        #expect(Self.script("   \n  ") == Self.script(nil))
    }

    // MARK: - 이스케이프 (급소)

    /// 작은따옴표가 그대로 새면 인용이 그 자리에서 닫히고 뒤가 명령이 된다.
    @Test func 작은따옴표를_가둔다() {
        let s = Self.script("don't stop")
        #expect(s.contains("'don'\\''t stop'"))
    }

    /// 백틱과 `$(...)` 는 작은따옴표 안에서는 실행되지 않는다. 그대로 남아야 한다.
    @Test func 명령치환을_실행되게_두지_않는다() {
        let s = Self.script("`rm -rf /` 와 $(whoami) 를 설명해라")
        #expect(s.contains("`rm -rf /` 와 $(whoami) 를 설명해라"))
        #expect(s.hasSuffix("'"))
    }

    /// `;` 로 명령을 이어붙이는 스크립트라 세미콜론이 새면 그 자리에서 잘린다.
    @Test func 세미콜론이_명령을_끊지_않는다() {
        let s = Self.script("빌드해라; 그리고 테스트해라")
        #expect(s.contains("'빌드해라; 그리고 테스트해라'"))
    }

    /// 여러 줄 브리핑은 실제로 흔하다. 작은따옴표 안에서 줄바꿈은 그대로 살아 있다.
    @Test func 줄바꿈이_든_브리핑도_한_인자다() {
        let s = Self.script("1. 로그인 개편\n2. 테스트 추가")
        #expect(s.contains("'1. 로그인 개편\n2. 테스트 추가'"))
    }

    // MARK: - 기존 조립을 깨지 않는다

    @Test func 모델과_함께_써도_순서가_맞다() {
        let s = Spawn.script(repoPath: "/repo", sessionID: "pane-1",
                             model: "opus", initialPrompt: "시작해라")
        let modelAt = try! #require(s.range(of: "--model"))
        let promptAt = try! #require(s.range(of: "'시작해라'"))
        #expect(modelAt.upperBound < promptAt.lowerBound)
    }

    @Test func 게이트_변수와_cd_는_그대로다() {
        let s = Self.script("브리핑")
        #expect(s.contains("export DURE_SESSION='pane-1'"))
        #expect(s.contains("cd '/repo'"))
        #expect(s.contains("exec claude"))
    }
}

/// 문자열 비교만으로는 이스케이프가 맞는지 알 수 없다. **진짜 zsh 에 넣어본다.**
/// 조립한 인용이 셸을 통과한 뒤에도 원문 그대로여야 한다.
///
/// (RED 를 먼저 보지 못했다 — `quoted` 는 이미 있던 코드다. 회귀 그물로 넣는다.)
struct SpawnQuotingThroughShellTests {

    static func echoThroughZsh(_ s: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Spawn.shell)
        // 인용 동작은 `-c` 와 `-ilc` 가 같다. `.zshrc` 가 stdout 을 더럽히지 않도록 `-c` 를 쓴다.
        p.arguments = ["-c", "printf '%s' \(Spawn.quoted(s))"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [
        "README 를 먼저 읽어라",
        "don't stop",
        "`rm -rf /` 를 설명만 해라",
        "$(whoami) 와 $HOME 을 출력하지 마라",
        "빌드해라; 그리고 테스트해라",
        "따옴표 \" 와 ' 가 섞인 문장",
        "1. 로그인 개편\n2. 테스트 추가",
        "백슬래시 \\ 와 파이프 | 와 앰퍼샌드 &",
        "이모지 🚀 와 한글 자모 ㅋㅋ",
    ])
    func 셸을_통과해도_원문_그대로다(_ prompt: String) throws {
        #expect(try Self.echoThroughZsh(prompt) == prompt)
    }
}
