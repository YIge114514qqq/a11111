import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: LessonStore
    @State private var query = ""

    private var filtered: [Lesson] {
        guard !query.isEmpty else { return store.lessons }
        return store.lessons.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.transcriptText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError = store.loadError {
                    // 数据读不出来时什么都不说就显示空列表，用户会以为课全丢了。
                    // 这里明确提示，并告诉他在哪里恢复。
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40)).foregroundStyle(.orange)
                        Text("课程数据没能读出来").font(.title3.bold())
                        Text(loadError).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("原始文件没有被覆盖。去「设置 → 从备份文件导入」，选之前导出的 JSON 恢复；也可以先导出备份把现有文件留存。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else if store.lessons.isEmpty {
                    emptyState
                } else {
                    lessonList
                }
            }
            .searchable(text: $query, prompt: "搜索课程或转写内容")
            .navigationTitle("课程")
            .navigationDestination(for: UUID.self) { id in
                LessonDetailView(lessonID: id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("还没有课程记录").font(.title3.bold())
            Text("回到「听课」录一节，结束后会自动出现在这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lessonList: some View {
        List {
            ForEach(filtered) { lesson in
                NavigationLink(value: lesson.id) {
                    LessonRow(lesson: lesson)
                }
            }
            .onDelete { offsets in
                let items = filtered
                for index in offsets where index < items.count {
                    store.delete(items[index])
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct LessonRow: View {
    let lesson: Lesson

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lesson.title)
                .font(.headline)
            if let first = lesson.lines.first?.text {
                Text(first)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Label(timeString(lesson.duration), systemImage: "clock")
                Label("\(lesson.lines.count) 句", systemImage: "text.bubble")
                if lesson.notes != nil {
                    Label("已生成笔记", systemImage: "sparkles")
                        .foregroundStyle(.indigo)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}