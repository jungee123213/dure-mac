import AppKit
import Foundation
import Observation

/// 이슈 #30 — 레포 경로에서 여는 바깥 터미널. 두레가 관할하지 않는다(훅도 상태도 없음, ADR-14).
/// 커밋 · push 는 사람이 여기서 한다(ADR-4).
enum ShellApp: Equatable, Sendable {
    case iTerm
    case terminal

    var bundleID: String {
        switch self {
        case .iTerm: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        }
    }

    var displayName: String {
        switch self {
        case .iTerm: "iTerm"
        case .terminal: "터미널"
        }
    }

    /// iTerm 이 없으면 기본 터미널. 누를 때마다 다시 고른다(나중에 iTerm 을 깔아도 따라온다).
    static func preferred(isInstalled: (String) -> Bool) -> ShellApp {
        isInstalled(ShellApp.iTerm.bundleID) ? .iTerm : .terminal
    }

    static func installedPreferred() -> ShellApp {
        preferred { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}

/// 앱에 보낼 AppleScript. 창은 `id` 로 가리킨다 — 사람이 창 순서를 바꿔도 같은 창을 닫는다.
enum RepoShellScript {
    /// 새 창을 열고 레포로 `cd` 한 뒤 창 번호를 돌려준다.
    /// 앞의 공백은 `HIST_IGNORE_SPACE` 를 쓰는 셸에서 기록에 남지 않게 하려는 것이다.
    static func open(_ app: ShellApp, path: String) -> String {
        let command = literal(" cd \(shellQuoted(path)) && clear")
        switch app {
        case .iTerm:
            return """
            tell application id "\(app.bundleID)"
                activate
                set w to (create window with default profile)
                tell current session of w to write text \(command)
                return id of w
            end tell
            """
        case .terminal:
            return """
            tell application id "\(app.bundleID)"
                activate
                set t to do script \(command)
                return id of (first window whose tabs contains t)
            end tell
            """
        }
    }

    /// 창이 아직 있나 — `true` / `false`. 앱이 꺼져 있으면 깨우지 않고 `false`.
    /// iTerm 은 닫은 창을 "닫기 되돌리기" 용으로 탭 0개인 채 목록에 남긴다(실측) — 탭까지 본다.
    static func exists(_ app: ShellApp, windowID: Int) -> String {
        """
        if application id "\(app.bundleID)" is running then
            tell application id "\(app.bundleID)"
                if not (exists window id \(windowID)) then return false
                return (count of tabs of window id \(windowID)) > 0
            end tell
        end if
        return false
        """
    }

    /// 이미 닫혔거나 앱이 꺼져 있으면 아무것도 안 한다.
    static func close(_ app: ShellApp, windowID: Int) -> String {
        """
        if application id "\(app.bundleID)" is running then
            tell application id "\(app.bundleID)"
                if exists window id \(windowID) then close window id \(windowID)
            end tell
        end if
        """
    }

    /// 셸 작은따옴표 인용. 안의 `'` 는 `'\''` 로 끊어 잇는다.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// AppleScript 문자열 리터럴(따옴표 포함).
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct AppleScriptError: Error, Equatable {
    var number: Int
    var message: String
}

protocol AppleScriptRunning {
    /// 결과를 글자로 돌려준다(정수 · 참거짓도 글자로 바뀐다).
    func run(_ source: String) throws -> String
}

/// `NSAppleScript` 는 메인 스레드에서 돈다. 자동화 권한 창이 Dure 이름으로 뜨게 하려고
/// `osascript` 를 띄우지 않고 앱 안에서 직접 보낸다.
struct LiveAppleScriptRunner: AppleScriptRunning {
    func run(_ source: String) throws -> String {
        var info: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError(number: 0, message: "스크립트를 만들지 못했습니다")
        }
        let result = script.executeAndReturnError(&info)
        if let info {
            throw AppleScriptError(number: info[NSAppleScript.errorNumber] as? Int ?? 0,
                                   message: info[NSAppleScript.errorMessage] as? String ?? "")
        }
        return result.stringValue ?? ""
    }
}

/// 레포별로 연 창 하나를 기억한다. 메모리에만 둔다 — 두레를 다시 켜면 예전 창과의 연결은 끊긴다.
@MainActor
@Observable
final class RepoShells {
    private struct Opened: Equatable {
        var app: ShellApp
        var windowID: Int
    }

    /// 레포 id → 연 창.
    private var opened: [String: Opened] = [:]
    /// 마지막으로 열기 · 닫기를 못 한 이유. 화면이 알림으로 띄우고 지운다.
    var problem: String?

    @ObservationIgnored private let runner: AppleScriptRunning
    @ObservationIgnored private let preferredApp: () -> ShellApp

    init(runner: AppleScriptRunning = LiveAppleScriptRunner(),
         preferredApp: @escaping () -> ShellApp = ShellApp.installedPreferred) {
        self.runner = runner
        self.preferredApp = preferredApp
    }

    func isOpen(_ repo: Repo) -> Bool { opened[repo.id] != nil }

    /// 열린 앱 이름. 닫혀 있으면 지금 누르면 열릴 앱.
    func appName(for repo: Repo) -> String {
        (opened[repo.id]?.app ?? preferredApp()).displayName
    }

    func toggle(_ repo: Repo) {
        if let o = opened[repo.id] {
            close(repo, o)
        } else {
            open(repo)
        }
    }

    /// 사람이 앱에서 직접 닫은 창을 잊는다. 두레로 돌아올 때 부른다.
    /// 확인이 실패하면 지우지 않는다 — 창이 남아 있는데 `열기` 로 바뀌면 그 창은 다시 닫을 수 없다.
    func refresh() {
        for (id, o) in opened {
            guard let answer = try? runner.run(RepoShellScript.exists(o.app, windowID: o.windowID)) else { continue }
            if answer == "false" { opened[id] = nil }
        }
    }

    private func open(_ repo: Repo) {
        guard repo.folderExists else {
            problem = "레포 폴더를 찾을 수 없습니다: \(repo.path)"
            return
        }
        let app = preferredApp()
        do {
            let answer = try runner.run(RepoShellScript.open(app, path: repo.path))
            guard let windowID = Int(answer) else {
                problem = "\(app.displayName) 창을 열었는지 확인하지 못했습니다."
                return
            }
            opened[repo.id] = Opened(app: app, windowID: windowID)
        } catch let e as AppleScriptError {
            problem = message(for: e, app: app, verb: "열지")
        } catch {
            problem = "\(app.displayName) 을 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func close(_ repo: Repo, _ o: Opened) {
        do {
            _ = try runner.run(RepoShellScript.close(o.app, windowID: o.windowID))
            opened[repo.id] = nil
        } catch let e as AppleScriptError {
            problem = message(for: e, app: o.app, verb: "닫지")
        } catch {
            problem = "\(o.app.displayName) 창을 닫지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func message(for e: AppleScriptError, app: ShellApp, verb: String) -> String {
        // -1743 = errAEEventNotPermitted. 한 번 거부하면 다시 묻지 않으므로 켜는 곳을 알려준다.
        if e.number == -1743 {
            return "Dure 가 \(app.displayName) 을 제어할 권한이 없습니다. 시스템 설정 › 개인정보 보호 및 보안 › 자동화 에서 Dure 의 \(app.displayName) 을 켜세요."
        }
        return "\(app.displayName) 창을 \(verb) 못했습니다 (\(e.number)): \(e.message)"
    }
}
