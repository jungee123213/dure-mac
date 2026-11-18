import SwiftUI

/// 이슈 #40 — 배분 작업 흐름 안내 창. 읽기 전용. 내용은 `WorkflowGuide`(조율자 지시문과 같은 원본)에서 온다.
/// DB · 스토어를 읽지 않는다.
struct WorkflowGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("작업 흐름").font(.title2).bold()

                section("단계") {
                    ForEach(WorkflowGuide.steps) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(s.id)").font(.caption).bold().frame(width: 18, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(s.title).font(.callout).bold()
                                    Text(s.who).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                section("배분 종류") {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("배분").bold(); Text("언제").bold(); Text("페인이 하는 git").bold()
                        }
                        .font(.caption)
                        Divider()
                        ForEach(WorkflowGuide.kinds) { k in
                            GridRow {
                                Text(k.name).bold()
                                Text(k.when).foregroundStyle(.secondary)
                                Text(k.git).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }

                section("승인 지점") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("② \"진행\" 한 번 — 이슈 등록 · 브랜치 · 커밋(· PR) 을 한꺼번에 승인한다.")
                        Text("③ 검증에서 어긋나면 그 페인 터미널에서 사람이 답한다.")
                        Text("레포 페인 설정에서 승인 없이 도는 push 는 git push -u origin <브랜치> 하나뿐이다. 다른 push 모양은 예전처럼 묻는다. 늘 묻는 명령 — force push · main/develop/master 직접 push · 원격 브랜치 삭제 · gh pr merge · git merge · rebase · reset --hard · 로컬 브랜치 삭제(-d/-D) · commit --amend.")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}
