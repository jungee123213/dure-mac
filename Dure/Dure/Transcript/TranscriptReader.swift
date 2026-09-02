import Foundation

/// 트랜스크립트를 **append 분만** 읽는다. 부록 A4 의 `read_cursor`.
enum TranscriptReader {

    struct Batch {
        /// (줄 번호, 줄 내용). 줄 번호는 파일 전체 기준 1-based.
        var lines: [(no: Int, data: Data)]
        var byteOffset: Int
        var lineNo: Int
    }

    /// - Parameters:
    ///   - offset: 지난번에 읽다 만 바이트 위치
    ///   - lineNo: 그때까지 읽은 줄 수
    ///
    /// **개행으로 끝나는 완전한 줄만** 돌려준다. 마지막 부분 줄은 다음 호출까지 보류한다
    /// (부록 A2 가 이벤트 파일에 정한 규칙과 같은 이유 — 쓰는 중인 줄을 반쯤 읽으면 안 된다).
    ///
    /// 파일이 커서보다 짧아졌으면 잘렸거나 교체된 것이므로 **0 부터 다시 읽는다.**
    static func read(path: String, offset: Int, lineNo: Int) -> Batch? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        var start = offset
        var startLine = lineNo
        if size < offset {
            start = 0
            startLine = 0
        }
        guard size > start else {
            return Batch(lines: [], byteOffset: start, lineNo: startLine)
        }

        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return Batch(lines: [], byteOffset: start, lineNo: startLine)
        }

        var lines: [(no: Int, data: Data)] = []
        var consumed = 0
        var current = startLine
        var cursor = data.startIndex

        while let nl = data[cursor...].firstIndex(of: UInt8(ascii: "\n")) {
            let slice = data[cursor..<nl]
            current += 1
            if !slice.isEmpty { lines.append((no: current, data: Data(slice))) }
            consumed = data.distance(from: data.startIndex, to: nl) + 1
            cursor = data.index(after: nl)
        }

        return Batch(lines: lines, byteOffset: start + consumed, lineNo: current)
    }
}
