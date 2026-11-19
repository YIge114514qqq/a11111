import SwiftUI
import UIKit

/// 复习时回看：当时圈了哪块、问了什么、AI 怎么讲的。
///
/// 为什么单独一页：讲解记录会越攒越多，塞进笔记页会把主体内容挤没。
/// 学生复习的真实顺序是「先看笔记框架 → 想不通再翻当时的讲解」，
/// 所以这里按时间倒序，最近的在前。
struct TutorLogView: View {
    let lessonID: UUID
    @EnvironmentObject var store: LessonStore
    @Environment(\.dismiss) private var dismiss

    private var lesson: Lesson? {
        store.lessons.first { $0.id == lessonID }
    }

    var body: some View {
        Group {
            if let entries = lesson?.tutorLog, !entries.isEmpty {
                list(entries)
            } else {
                empty
            }
        }
        .navigationTitle("讲解记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 42))
                .foregroundStyle(.indigo)
            Text("还没有讲解记录").font(.title3.bold())
            Text("打开课件，用「圈选提问」圈住不懂的地方，讲解会自动存到这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ entries: [TutorEntry]) -> some View {
        List {
            ForEach(entries) { entry in
                Section {
                    // 当时圈的那块截图，一眼就想起来问的是什么
                    if let name = entry.imageFileName,
                       FileManager.default.fileExists(atPath: store.fileURL(named: name).path),
                       let image = UIImage(contentsOfFile: store.fileURL(named: name).path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    ForEach(entry.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title)
                                .font(.caption.bold())
                                .foregroundStyle(.indigo)
                            Text(step.body).font(.callout)
                        }
                        .padding(.vertical, 2)
                    }

                    if !entry.followUpQuestion.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当时留的思考题")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                            Text(entry.followUpQuestion).font(.callout)
                        }
                    }
                } header: {
                    HStack {
                        Text("第 \(entry.pageIndex) 页")
                        Spacer()
                        Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption2)
                    }
                }
            }
            .onDelete { offsets in
                delete(offsets, from: entries)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func delete(_ offsets: IndexSet, from entries: [TutorEntry]) {
        guard var updated = lesson else { return }
        for index in offsets where index < entries.count {
            // 截图文件也要删，否则沙盒里会堆一堆没人引用的图片
            store.deleteFile(named: entries[index].imageFileName)
            updated.tutorLog.removeAll { $0.id == entries[index].id }
        }
        store.save(updated)
    }
}
