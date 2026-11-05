// Dure/DureTests/TestHostTests.swift
import Foundation
import Testing
@testable import Dure

/// 이슈 #29 — 유닛 테스트 호스트로 뜬 Dure 는 앱 본체를 시작하지 않는다.
/// 시작하면 실제 DB 를 마이그레이션하고, `~/.dure/events` 의 훅 이벤트를 읽고 지워 실행 중인 진짜 두레가 놓친다.
@MainActor
struct TestHostTests {

    @Test func XCTest_설정_경로가_있으면_테스트_호스트() {
        #expect(TestHost.isActive(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        #expect(!TestHost.isActive([:]))
        #expect(!TestHost.isActive(["HOME": "/Users/me"]))
    }

    @Test func 이_테스트_프로세스에서는_앱_본체가_시작되지_않았다() {
        #expect(TestHost.isActive(ProcessInfo.processInfo.environment))
        #expect(!DureApp.didLaunch)
    }

    @Test func 테스트_호스트에서_실제_DB_를_열면_실패한다() {
        #expect(throws: AppDatabase.OpenError.testHost) {
            try AppDatabase.makeQueue(environment: ["XCTestConfigurationFilePath": "/tmp/x"])
        }
    }

    @Test func 설정은_UserDefaults_와_메모리_저장소_어느_쪽에도_같게_쓰인다() {
        let m = MemorySettings()
        var s = ObserverSettings(); s.minTurns = 7; s.excludes = ["/x/"]; s.autoEvaluate = false
        s.save(to: m)
        #expect(ObserverSettings.load(from: m) == s)
        #expect(ObserverSettings.firstStart(in: m, now: 5) == 5)
        #expect(ObserverSettings.firstStart(in: m, now: 9) == 5)
    }
}
