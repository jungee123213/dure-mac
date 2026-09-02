import Foundation

/// `~/.dure/events/` 를 소비해 매핑 테이블을 갱신한다 (Step 4 · F2).
///
/// **설계문서는 FSEvents 라고 적었으나 `DispatchSource` 를 쓴다.**
/// 부록 A2 v6 에서 이벤트가 파일 단위가 되면서 필요한 것이 "디렉토리에 항목이 생겼나"
/// 하나로 줄었고, 그건 vnode 감시로 충분하다. FSEvents 의 C 콜백을 Swift 6 동시성
/// 아래로 끌고 오는 비용(ADR-10 비용 3)을 치를 이유가 없다.
/// **놓칠 걱정도 없다** — 시작할 때 디렉토리를 통째로 훑고(drain) 나서 감시를 건다.
@MainActor
final class EventIngestor {

    private weak var store: DureStore?
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    func start(store: DureStore) {
        self.store = store
        drain()   // 앱이 꺼져 있는 동안 쌓인 것부터 먹는다
        watch()
    }

    deinit { source?.cancel() }

    // MARK: - 감시

    private func watch() {
        guard source == nil else { return }
        let fd = open(HookBridge.eventsDir.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[Dure] 이벤트 디렉토리를 열 수 없다: \(HookBridge.eventsDir.path)")
            return
        }
        descriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler {
            // 큐가 .main 이므로 메인액터 위다. 부록 A5 — 콜백에서 상태를 직접 만지지 않는다.
            MainActor.assumeIsolated { [weak self] in self?.drain() }
        }
        src.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source = src
        src.resume()
    }

    // MARK: - 소비

    /// `.json` 만 읽는다. `.tmp` 는 훅이 아직 쓰는 중이라 건드리지 않는다.
    /// 파일명이 나노초·PID·난수라 **사전순이 곧 시간순**이다.
    func drain() {
        guard let store else { return }
        let fm = FileManager.default
        let dir = HookBridge.eventsDir
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }

            guard let event = HookEvent(data: data) else {
                // 조용히 버리면 원인을 못 찾는다. 이름만 바꿔 남긴다 (부록 A2).
                quarantine(url)
                continue
            }
            guard event.isSupported else {
                NSLog("[Dure] 모르는 이벤트 버전 v=\(event.v). 무시한다")
                try? fm.removeItem(at: url)
                continue
            }

            store.apply(event)
            try? fm.removeItem(at: url)
        }
    }

    private func quarantine(_ url: URL) {
        let bad = url.deletingPathExtension().appendingPathExtension("bad")
        try? FileManager.default.moveItem(at: url, to: bad)
        NSLog("[Dure] 이벤트 파싱 실패. 격리: \(bad.lastPathComponent)")
    }
}
