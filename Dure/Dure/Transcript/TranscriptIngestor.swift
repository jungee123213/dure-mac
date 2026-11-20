import Foundation
import GRDB

/// 트랜스크립트 → `token_usage` · `tool_use`. Step 5 (F6 · F7).
///
/// **파일 감시를 두지 않는다.** 훅이 이미 "응답이 끝났다"(`Stop`)를 알려주므로
/// 그때 읽으면 된다 (ADR-3 — 상태는 훅에서). 세션마다 파일 감시자를 다는 것보다 싸고,
/// 앱이 꺼져 있던 동안의 분량은 커서 덕에 다음 실행에서 이어 읽는다.
enum TranscriptIngestor {

    struct Result: Equatable {
        var usageRows = 0
        var toolRows = 0
        var linesRead = 0
    }

    /// 한 세션의 트랜스크립트에서 **새로 붙은 줄만** 읽어 반영한다.
    @discardableResult
    static func ingest(_ session: CCSession, in db: Database,
                       now: Int = Int(Date().timeIntervalSince1970)) throws -> Result {
        let cursor = try ReadCursor.fetchOne(db, key: session.transcriptPath)
        guard let batch = TranscriptReader.read(path: session.transcriptPath,
                                                offset: cursor?.byteOffset ?? 0,
                                                lineNo: cursor?.lineNo ?? 0)
        else { return Result() }

        var result = Result(usageRows: 0, toolRows: 0, linesRead: batch.lines.count)
        var model = session.model

        for line in batch.lines {
            let ts = (try? JSONSerialization.jsonObject(with: line.data) as? [String: Any])
                .flatMap { TranscriptParser.timestamp($0) } ?? now

            if let parsed = TranscriptParser.parse(line.data) {
                if let u = parsed.usage {
                    // 같은 응답의 둘째·셋째 줄은 같은 행을 덮어쓴다. 그래서 2배가 되지 않는다 (A7-1).
                    try save(u, line: line.no, ts: ts, session: session, db: db)
                    result.usageRows += 1
                }
                if let t = parsed.tool {
                    try save(t, line: line.no, ts: ts, session: session, db: db)
                    result.toolRows += 1
                }
                continue
            }

            guard let codex = CodexTranscriptParser.parse(line.data) else { continue }
            switch codex {
            case .model(let m):
                model = m
            case .usage(var u, _):
                u.model = model
                try save(u, line: line.no, ts: ts, session: session, db: db)
                result.usageRows += 1
            case .tool(let t, _):
                try save(t, line: line.no, ts: ts, session: session, db: db)
                result.toolRows += 1
            }
        }

        if model != session.model {
            try db.execute(sql: "UPDATE cc_session SET model = ? WHERE cc_session_id = ?",
                           arguments: [model, session.ccSessionId])
        }

        try ReadCursor(path: session.transcriptPath,
                       byteOffset: batch.byteOffset,
                       lineNo: batch.lineNo,
                       updatedAt: now).save(db)
        return result
    }

    private static func save(_ u: TranscriptParser.Usage, line: Int, ts: Int,
                             session: CCSession, db: Database) throws {
        try TokenUsage(ccSessionId: session.ccSessionId, messageId: u.messageId, lineNo: line,
                       ts: ts, input: u.input, output: u.output, cacheRead: u.cacheRead,
                       cacheCreation: u.cacheCreation, thinking: u.thinking,
                       serviceTier: u.serviceTier, model: u.model).save(db)
    }

    private static func save(_ t: TranscriptParser.Tool, line: Int, ts: Int,
                             session: CCSession, db: Database) throws {
        try ToolUse(ccSessionId: session.ccSessionId, lineNo: line, ts: ts, toolName: t.name,
                    mcpServer: t.mcpServer, skillName: t.skillName).save(db)
    }
}

/// F6 화면이 쓸 합계. 부록 A7-1 의 표시 정책을 여기 한 곳에 둔다.
struct UsageTotals: Equatable {
    var input = 0, output = 0, cacheRead = 0, cacheCreation = 0, thinking = 0
    var responses = 0

    /// 실제로 비싸게 청구되는 부분. **`cacheRead` 는 일부러 뺀다.**
    var headline: Int { input + cacheCreation + output }

    static func of(_ rows: [TokenUsage]) -> UsageTotals {
        var t = UsageTotals()
        for r in rows {
            t.input += r.input
            t.output += r.output
            t.cacheRead += r.cacheRead
            t.cacheCreation += r.cacheCreation
            t.thinking += r.thinking
        }
        t.responses = rows.count
        return t
    }
}
