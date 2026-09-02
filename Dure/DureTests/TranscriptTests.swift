import Foundation
import GRDB
import Testing
@testable import Dure

/// Step 5 · F6 · F7 — 트랜스크립트 → 토큰 · 툴 로그.
///
/// 아래 세 줄은 **실제 트랜스크립트에서 뽑아 본문만 지운 것**이다
/// (대화 내용은 뺐고, 파서가 읽는 필드와 숫자는 원본 그대로).
/// 한 응답(`message.id` 하나)이 content 블록 개수만큼 **3줄**로 기록되고
/// 각 줄이 `usage` 를 통째로 복사해 갖는 실물 구조다 — 부록 A7-1 이 경고한 그것.
struct TranscriptTests {

    static let thinkingLine = #"{"type":"assistant","sessionId":"REDACTED","message":{"id":"msg_A","model":"claude-fable-5","content":[{"type":"thinking"}],"usage":{"input_tokens":2,"output_tokens":3550,"cache_read_input_tokens":26760,"cache_creation_input_tokens":62728,"service_tier":"standard","output_tokens_details":{"thinking_tokens":334}}}}"#
    static let textLine = #"{"type":"assistant","sessionId":"REDACTED","message":{"id":"msg_A","model":"claude-fable-5","content":[{"type":"text"}],"usage":{"input_tokens":2,"output_tokens":3550,"cache_read_input_tokens":26760,"cache_creation_input_tokens":62728,"service_tier":"standard","output_tokens_details":{"thinking_tokens":334}}}}"#
    static let toolLine = #"{"type":"assistant","sessionId":"REDACTED","message":{"id":"msg_A","model":"claude-fable-5","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}],"usage":{"input_tokens":2,"output_tokens":3550,"cache_read_input_tokens":26760,"cache_creation_input_tokens":62728,"service_tier":"standard","output_tokens_details":{"thinking_tokens":334}}}}"#

    // MARK: - 파싱 (A7-1)

    @Test func usage_네_값과_thinking_을_전부_읽는다() throws {
        let p = try #require(TranscriptParser.parse(Data(Self.thinkingLine.utf8)))
        let u = try #require(p.usage)
        #expect(u.messageId == "msg_A")
        #expect(u.input == 2)
        #expect(u.output == 3550)
        #expect(u.cacheRead == 26760)
        #expect(u.cacheCreation == 62728)
        #expect(u.thinking == 334)
        #expect(u.serviceTier == "standard")
        #expect(u.model == "claude-fable-5")
    }

    @Test func assistant_가_아닌_줄은_무시한다() {
        #expect(TranscriptParser.parse(Data(#"{"type":"user","message":{}}"#.utf8)) == nil)
        #expect(TranscriptParser.parse(Data("깨진 줄".utf8)) == nil)
    }

    // MARK: - 판별 (A7-2)

    @Test func MCP_스킬_일반툴을_구분한다() {
        let mcp = TranscriptParser.classify(name: "mcp__playwright__browser_navigate", input: nil)
        #expect(mcp.mcpServer == "playwright")
        #expect(mcp.skillName == nil)

        let skill = TranscriptParser.classify(name: "Skill", input: ["skill": "superpowers:brainstorming"])
        // plugin:skill 형태를 쪼개지 않고 통째로 저장한다.
        #expect(skill.skillName == "superpowers:brainstorming")
        #expect(skill.mcpServer == nil)

        let plain = TranscriptParser.classify(name: "Bash", input: nil)
        #expect(plain.mcpServer == nil && plain.skillName == nil)
    }

    /// A7-2 — 서버명에 `__` 가 들어가 3조각이 아니면 **추측하지 않는다.**
    /// 조용히 틀린 이름을 넣는 것이 제일 나쁘다.
    @Test func MCP_이름이_3조각이_아니면_서버명을_비운다() {
        let odd = TranscriptParser.classify(name: "mcp__weird__server__tool", input: nil)
        #expect(odd.name == "mcp__weird__server__tool")
        #expect(odd.mcpServer == nil)
    }

    // MARK: - 증분 읽기

    @Test func 완전한_줄만_읽고_쓰이는_중인_줄은_보류한다() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try "첫줄\n둘째줄\n쓰다만".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try #require(TranscriptReader.read(path: url.path, offset: 0, lineNo: 0))
        #expect(first.lines.count == 2)
        #expect(first.lineNo == 2)

        // 나머지가 붙어 완결되면 그때 읽힌다.
        try "쓰다만끝\n".write(to: url, atomically: false, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.close()

        let second = try #require(TranscriptReader.read(path: url.path,
                                                        offset: first.byteOffset,
                                                        lineNo: first.lineNo))
        #expect(second.lines.count == 1)
    }

    // MARK: - 반영 (핵심)

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo", label: nil, model: nil).insert(db)
            try Agent(dureSession: "pane", repoId: "r1", agentKind: "claude",
                      state: "started", model: nil, startedAt: 0, endedAt: nil).insert(db)
        }
        return q
    }

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// **이 프로젝트에서 제일 잘 틀리는 곳.** 한 응답이 3줄이지만 토큰은 1회만 세야 한다.
    /// 줄마다 더하면 output 3550 이 10650 이 된다 (A7-1 실측 2.37배의 원인).
    @Test func 한_응답이_세_줄이어도_토큰은_한_번만_센다() throws {
        let q = try makeDB()
        let url = try write([Self.thinkingLine, Self.textLine, Self.toolLine])
        defer { try? FileManager.default.removeItem(at: url) }
        let session = CCSession(ccSessionId: "cc1", dureSession: "pane",
                                transcriptPath: url.path, source: "startup",
                                model: nil, startedAt: 0)
        try q.write { try session.insert($0) }

        let result = try q.write { try TranscriptIngestor.ingest(session, in: $0) }
        #expect(result.linesRead == 3)

        let rows = try q.read { try TokenUsage.fetchAll($0) }
        #expect(rows.count == 1)              // 3줄 → 1행
        let totals = UsageTotals.of(rows)
        #expect(totals.output == 3550)        // 10650 이 아니다
        #expect(totals.cacheRead == 26760)
        #expect(totals.thinking == 334)
        // A7-1 표시 정책 — cache_read 는 헤드라인에 넣지 않는다.
        #expect(totals.headline == 2 + 62728 + 3550)

        // tool_use 는 message.id 로 접으면 안 된다. 블록이 사라진다.
        let tools = try q.read { try ToolUse.fetchAll($0) }
        #expect(tools.count == 1)
        #expect(tools[0].toolName == "Bash")
    }

    @Test func 두_번_읽어도_숫자가_변하지_않는다() throws {
        let q = try makeDB()
        let url = try write([Self.thinkingLine, Self.textLine, Self.toolLine])
        defer { try? FileManager.default.removeItem(at: url) }
        let session = CCSession(ccSessionId: "cc1", dureSession: "pane",
                                transcriptPath: url.path, source: "startup",
                                model: nil, startedAt: 0)
        try q.write { try session.insert($0) }

        try q.write { try TranscriptIngestor.ingest(session, in: $0) }
        let again = try q.write { try TranscriptIngestor.ingest(session, in: $0) }
        // 커서가 끝에 있으므로 두 번째에는 읽을 줄이 없다.
        #expect(again.linesRead == 0)
        #expect(try q.read { try TokenUsage.fetchCount($0) } == 1)
        #expect(UsageTotals.of(try q.read { try TokenUsage.fetchAll($0) }).output == 3550)
    }

    /// 실제 트랜스크립트로 `docs/step1/tokens.sh` · `tools.sh` 와 **숫자를 대조한다.**
    /// 픽스처는 구조를 고정할 뿐이고, 진짜 검증은 실물이 jq 와 일치하는지다.
    ///
    ///     TEST_RUNNER_DURE_TRANSCRIPT=<파일.jsonl> \
    ///     TEST_RUNNER_DURE_EXPECT=<responses,input,output,cache_creation,cache_read,thinking,tools> \
    ///     xcodebuild ... -only-testing:DureTests test
    ///
    /// 기대값은 `sh docs/step1/tokens.sh <파일>` 과 `tools.sh` 의 출력에서 가져온다.
    /// 환경변수가 없으면 건너뛴다. (`xcodebuild` 는 `TEST_RUNNER_` 접두사가 붙은 것만 전달한다.)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DURE_TRANSCRIPT"] != nil))
    func 실물_트랜스크립트가_jq_와_같은_숫자를_낸다() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["DURE_TRANSCRIPT"])
        let expected = try #require(env["DURE_EXPECT"]).split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        try #require(expected.count == 7)

        let q = try makeDB()
        let session = CCSession(ccSessionId: "cc-real", dureSession: "pane",
                                transcriptPath: path, source: "startup",
                                model: nil, startedAt: 0)
        try q.write { try session.insert($0) }
        try q.write { try TranscriptIngestor.ingest(session, in: $0) }

        let totals = UsageTotals.of(try q.read { try TokenUsage.fetchAll($0) })
        let tools = try q.read { try ToolUse.fetchCount($0) }

        #expect(totals.responses == expected[0])      // jq: group_by(message.id) | length
        #expect(totals.input == expected[1])
        #expect(totals.output == expected[2])
        #expect(totals.cacheCreation == expected[3])
        #expect(totals.cacheRead == expected[4])
        #expect(totals.thinking == expected[5])
        #expect(tools == expected[6])                 // jq: unique_by(tool_use.id) | length
    }

    @Test func 뒤에_붙은_줄만_이어_읽는다() throws {
        let q = try makeDB()
        let url = try write([Self.thinkingLine])
        defer { try? FileManager.default.removeItem(at: url) }
        let session = CCSession(ccSessionId: "cc1", dureSession: "pane",
                                transcriptPath: url.path, source: "startup",
                                model: nil, startedAt: 0)
        try q.write { try session.insert($0) }
        try q.write { try TranscriptIngestor.ingest(session, in: $0) }

        let more = Self.toolLine.replacingOccurrences(of: "msg_A", with: "msg_B")
        try (Self.thinkingLine + "\n" + more + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let result = try q.write { try TranscriptIngestor.ingest(session, in: $0) }
        #expect(result.linesRead == 1)        // 새로 붙은 한 줄만
        #expect(try q.read { try TokenUsage.fetchCount($0) } == 2)
    }
}
