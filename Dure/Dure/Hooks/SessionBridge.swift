import Foundation
import GRDB

/// ADR-17 브리지의 순수 로직. `DureStore` 밖으로 뺀 이유는 **인메모리 DB 로 테스트하기
/// 위해서다.** 여기가 틀리면 F6·F7 이 통째로 조용히 죽는다.
enum SessionBridge {

    enum Outcome: Equatable {
        case recorded          // cc_session 한 행이 들어갔다
        case unknownAgent      // 앱이 모르는 dure_session. 건너뛴다
        case missingFields     // session_id / transcript_path 가 없다
    }

    @discardableResult
    static func apply(_ event: HookEvent, in db: Database) throws -> Outcome {
        guard let ccID = event.ccSessionID, let path = event.transcriptPath else {
            return .missingFields
        }
        // `cc_session` 이 `agent` 를 참조하므로 없는 채로 넣으면 외래키에서 터진다.
        // 앱을 다시 깐 뒤 남아 있던 이벤트가 들어오는 경우가 실제로 있다.
        guard try Agent.filter(key: event.dureSession).fetchOne(db) != nil else {
            return .unknownAgent
        }
        // `/clear` 는 **새 행**을 만든다 (1:N). 같은 cc_session_id 재발화면 갱신한다.
        try CCSession(ccSessionId: ccID,
                      dureSession: event.dureSession,
                      transcriptPath: path,
                      source: event.source,
                      model: event.model,
                      startedAt: Int(Date().timeIntervalSince1970)).save(db)
        return .recorded
    }
}
