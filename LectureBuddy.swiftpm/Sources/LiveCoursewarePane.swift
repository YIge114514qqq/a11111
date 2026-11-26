import PDFKit
import SwiftUI
import UIKit

/// 听课时浏览课件。页码由听课页持有，收起分屏后还能接着读。
struct LiveCoursewarePane: View {
    let document: PDFDocument?
    let image: UIImage?
    let fileName: String
    @Binding var pageIndex: Int
    let onReplace: () -> Void

    private var pageCount: Int { document?.pageCount ?? (image == nil ? 0 : 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onReplace) {
                    Image(systemName: "folder")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("更换课件")
            }
            .padding(.leading, 12)

            Divider()

            Group {
                if let document {
                    LiveCoursewarePDFView(document: document, pageIndex: $pageIndex)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("课堂课件图片")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if pageCount > 0 {
                Divider()
                HStack(spacing: 12) {
                    if pageCount > 1 {
                        Button {
                            pageIndex -= 1
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(pageIndex <= 0)
                        .accessibilityLabel("上一页")
                    }

                    Text("\(pageIndex + 1) / \(pageCount)")
                        .font(.subheadline.monospacedDigit())
                        .accessibilityLabel("第 \(pageIndex + 1) 页，共 \(pageCount) 页")

                    if pageCount > 1 {
                        Button {
                            pageIndex += 1
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 44, height: 44)
                        }
                        .disabled(pageIndex >= pageCount - 1)
                        .accessibilityLabel("下一页")
                    }
                }
                .frame(minHeight: 44)
            }
        }
        .background(.background)
    }
}

private struct LiveCoursewarePDFView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = .systemBackground
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        view.autoScales = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pageIndex = $pageIndex
        let documentChanged = view.document !== document
        // 字幕更新也可能触发 SwiftUI 刷新，只在课件或目标页变化时导航。
        guard documentChanged || coordinator.lastRequestedIndex != pageIndex else { return }
        coordinator.lastRequestedIndex = pageIndex
        coordinator.isApplyingSelection = true
        defer { coordinator.isApplyingSelection = false }
        if documentChanged {
            view.document = document
            view.autoScales = true
        }
        if let page = document.page(at: pageIndex), view.currentPage !== page {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pageIndex: $pageIndex) }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.isRemoved = true
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: view)
    }

    @MainActor
    final class Coordinator: NSObject {
        var pageIndex: Binding<Int>
        var lastRequestedIndex: Int?
        var isApplyingSelection = false
        var isRemoved = false

        init(pageIndex: Binding<Int>) {
            self.pageIndex = pageIndex
        }

        @objc func pageChanged(_ notification: Notification) {
            guard !isApplyingSelection, let view = notification.object as? PDFView,
                  let document = view.document, let page = view.currentPage else { return }
            let index = document.index(for: page)
            let previousIndex = pageIndex.wrappedValue
            guard (0..<document.pageCount).contains(index), index != previousIndex else { return }

            // PDFKit 也可能在布局时发通知，等本轮 SwiftUI 更新结束再同步页码。
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.isRemoved,
                      view.document === document, view.currentPage === page,
                      self.pageIndex.wrappedValue == previousIndex else { return }
                self.lastRequestedIndex = index
                self.pageIndex.wrappedValue = index
            }
        }
    }
}
