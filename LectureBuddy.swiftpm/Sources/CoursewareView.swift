import SwiftUI
import PDFKit
import Vision
import UIKit

/// 课件阅读 + 批注 + 圈选讲解。
///
/// 设计取舍：
/// - 页面按固定逻辑尺寸渲染（A4 比例 595x842pt），不跟随屏幕缩放。
///   这样批注坐标永远稳定，换设备也不会错位。
/// - 圈选后先跑 OCR，拿到置信度；只有「不确定」或「像公式」才升级到视觉模型。
///   这样日常提问几乎不花钱，只有真需要看图时才付那份成本。
struct CoursewareView: View {
    let lessonID: UUID
    private let initialPage: Int

    init(lessonID: UUID, initialPage: Int = 0) {
        self.lessonID = lessonID
        self.initialPage = initialPage
    }

    @EnvironmentObject var store: LessonStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showImporter = false
    @State private var pdfDocument: PDFDocument?
    @State private var pageIndex = 0
    @State private var pageCount = 0
    @State private var pageImage: UIImage?
    @State private var canvasHandle: CanvasHandle?
    @State private var drawingIsLoaded = false
    @State private var tool: PencilCanvasView.CanvasTool = .pen
    @State private var loadError: String?

    @State private var tutorBusy = false
    @State private var tutorError: String?
    @State private var tutorSteps: [TutorStep] = []
    @State private var tutorFollowUp = ""
    @State private var usedVision = false
    @State private var showTutorSheet = false
    @State private var selectedImage: UIImage?
    @State private var tutorRequestID: UUID?
    @State private var tutorTask: Task<Void, Never>?

    /// A4 比例，PDF 常用尺寸；批注坐标系固定用它
    private let canvasSize = CGSize(width: 595, height: 842)

    private var lesson: Lesson? {
        store.lessons.first { $0.id == lessonID }
    }

    var body: some View {
        Group {
            if let lesson, let name = lesson.coursewareFileName,
               FileManager.default.fileExists(atPath: store.fileURL(named: name).path) {
                reader(lesson: lesson, fileName: name)
            } else {
                importPrompt
            }
        }
        .navigationTitle("课件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") {
                    saveCurrentDrawing()
                    dismiss()
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showTutorSheet) {
            tutorSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onDisappear {
            saveCurrentDrawing()
            tutorTask?.cancel()
            tutorTask = nil
            tutorRequestID = nil
            tutorBusy = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveCurrentDrawing() }
        }
        .onChange(of: canvasHandle?.canvas != nil) { _, isReady in
            // 画布句柄异步建立，首次 onAppear 时可能还不能恢复笔迹。
            if isReady, !drawingIsLoaded, let lesson {
                restoreDrawing(lesson: lesson, page: pageIndex)
            }
        }
    }

    private var importPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 46))
                .foregroundStyle(.indigo)
            Text("还没有课件").font(.title3.bold())
            Text("导入这节课的 PDF 或图片，可以直接在上面用 Apple Pencil 写字、划重点。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showImporter = true
            } label: {
                Label("导入课件", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.pink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reader(lesson: Lesson, fileName: String) -> some View {
        VStack(spacing: 0) {
            toolbar(lesson: lesson)
            ZStack(alignment: .topTrailing) {
                PencilCanvasView(
                    pageImage: pageImage,
                    canvasSize: canvasSize,
                    tool: tool,
                    onSelection: { rect in
                        handleSelection(rect, lesson: lesson)
                    },
                    canvasHandle: $canvasHandle
                )
                if tutorBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在讲解…").font(.footnote)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                }
            }
        }
        .onAppear {
            if pageImage == nil { loadDocument(fileName: fileName, lesson: lesson, page: initialPage) }
        }
    }

    private func toolbar(lesson: Lesson) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    annotationTools
                    Divider().frame(height: 22)
                    pageControls(lesson: lesson)
                }
                VStack(alignment: .leading, spacing: 0) {
                    annotationTools
                    pageControls(lesson: lesson)
                }
            }

            if tool == .select {
                Text("单指从题目一角拖到对角，松手即可提问。双指可以移动和缩放课件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.25))
    }

    private var annotationTools: some View {
        HStack(spacing: 6) {
            Button { tool = .pen } label: { toolIcon("pencil.tip", .pen) }
                .accessibilityLabel("铅笔")
            Button { tool = .highlighter } label: { toolIcon("highlighter", .highlighter) }
                .accessibilityLabel("荧光笔")
            Button { tool = .eraser } label: { toolIcon("eraser", .eraser) }
                .accessibilityLabel("橡皮")
            Button { tool = .select } label: {
                Label("圈选提问", systemImage: "lasso")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tool == .select ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(tool == .select ? Color.indigo : Color.indigo.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityAddTraits(tool == .select ? .isSelected : [])
            .disabled(pageImage == nil)
        }
    }

    private func pageControls(lesson: Lesson) -> some View {
        HStack(spacing: 6) {
            Button { goTo(pageIndex - 1, lesson: lesson) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("上一页")
            .disabled(pageIndex <= 0)

            Text("\(pageIndex + 1) / \(max(pageCount, 1))")
                .font(.caption.monospacedDigit())
                .fixedSize()

            Button { goTo(pageIndex + 1, lesson: lesson) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("下一页")
            .disabled(pageIndex >= pageCount - 1)

            Spacer()

            Button { showImporter = true } label: {
                Text("换课件")
                    .font(.footnote)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private func toolIcon(_ name: String, _ value: PencilCanvasView.CanvasTool) -> some View {
        Image(systemName: name)
            .font(.system(size: 17))
            .frame(width: 44, height: 44)
            .background(tool == value ? Color.indigo.opacity(0.3) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

// MARK: - 加载与渲染

extension CoursewareView {

    private func loadDocument(fileName: String, lesson: Lesson, page: Int = 0) {
        // 换课件时不能把旧画布写到新课件；恢复完成后才允许保存。
        drawingIsLoaded = false
        let url = store.fileURL(named: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "课件文件不见了（可能换机时没带过来）。"
            return
        }
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else {
                loadError = "这个 PDF 打不开，可能已损坏。"
                return
            }
            pdfDocument = doc
            pageCount = doc.pageCount
            goTo(page, lesson: lesson)
        } else if let image = UIImage(contentsOfFile: url.path) {
            pdfDocument = nil
            pageCount = 1
            pageImage = renderImagePage(image)
            restoreDrawing(lesson: lesson, page: 0)
        } else {
            loadError = "这张图片读不出来。"
        }
    }

    private func goTo(_ index: Int, lesson: Lesson) {
        let target = max(0, min(index, max(pageCount - 1, 0)))
        // 翻页前先把当前页的笔画存回这节课，否则翻回来就没了
        saveCurrentDrawing()
        pageIndex = target
        if let doc = pdfDocument, let page = doc.page(at: target) {
            pageImage = render(page: page)
        }
        restoreDrawing(lesson: lesson, page: target)
    }

    private func saveCurrentDrawing() {
        // 从 store 取最新课程，避免生命周期回调把其他刚保存的内容覆盖掉。
        guard drawingIsLoaded, let data = canvasHandle?.drawingData(),
              var updated = lesson else { return }
        if pageIndex < updated.annotations.count,
           updated.annotations[pageIndex] == data { return }
        while updated.annotations.count <= pageIndex {
            updated.annotations.append(Data())
        }
        updated.annotations[pageIndex] = data
        store.save(updated)
    }

    private func restoreDrawing(lesson: Lesson, page: Int) {
        drawingIsLoaded = false
        guard let canvasHandle, canvasHandle.canvas != nil else { return }
        let data = page < lesson.annotations.count ? lesson.annotations[page] : nil
        canvasHandle.loadDrawing(data)
        drawingIsLoaded = true
    }

    /// 把 PDF 页渲染成固定尺寸的图片。
    /// 用 canvasSize 而不是页面原始尺寸，是为了让批注坐标系固定不变。
    private func render(page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return UIImage() }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2   // 2x 足够清晰，又不至于让内存爆掉
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvasSize))

            let cg = ctx.cgContext
            cg.saveGState()
            // PDF 坐标原点在左下，UIKit 在左上，先翻转
            cg.translateBy(x: 0, y: canvasSize.height)
            cg.scaleBy(x: 1, y: -1)

            let scale = min(canvasSize.width / bounds.width,
                            canvasSize.height / bounds.height)
            let offsetX = (canvasSize.width - bounds.width * scale) / 2
            let offsetY = (canvasSize.height - bounds.height * scale) / 2
            cg.translateBy(x: offsetX, y: offsetY)
            cg.scaleBy(x: scale, y: scale)

            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
    }

    private func renderImagePage(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: canvasSize))
            let scale = min(canvasSize.width / image.size.width,
                            canvasSize.height / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(in: CGRect(x: (canvasSize.width - w) / 2,
                                  y: (canvasSize.height - h) / 2,
                                  width: w, height: h))
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, var lesson else { return }
            do {
                let name = try store.importFile(from: url)
                lesson.coursewareFileName = name
                lesson.annotations = []
                store.save(lesson)
                loadError = nil
                pageIndex = 0
                loadDocument(fileName: name, lesson: lesson)
            } catch {
                loadError = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            loadError = "选择文件失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 圈选 → 讲解

extension CoursewareView {

    private func handleSelection(_ rect: CGRect, lesson: Lesson) {
        tutorTask?.cancel()
        tutorTask = nil
        let requestID = UUID()
        tutorRequestID = requestID
        tutorBusy = false
        tutorError = nil
        tutorSteps = []
        tutorFollowUp = ""
        usedVision = false
        selectedImage = nil
        guard let crop = cropImage(rect: rect) else {
            tutorError = "没能截到这块内容，放大一点再圈一次。"
            showTutorSheet = true
            return
        }
        tutorBusy = true
        selectedImage = crop
        showTutorSheet = true
        let pageNumber = pageIndex + 1
        tutorTask = Task {
            await runTutor(crop: crop, lesson: lesson, pageNumber: pageNumber, requestID: requestID)
        }
    }

    /// 从当前页面图里裁出圈选区域。
    /// UIImage.size 是逻辑点，CGImage 裁剪使用像素，必须按实际像素宽高换算。
    private func cropImage(rect: CGRect) -> UIImage? {
        guard let pageImage, let cg = pageImage.cgImage else { return nil }
        let selection = rect.standardized.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !selection.isNull, selection.width >= 8, selection.height >= 8 else { return nil }
        let scaleX = CGFloat(cg.width) / canvasSize.width
        let scaleY = CGFloat(cg.height) / canvasSize.height
        let scaled = CGRect(x: selection.minX * scaleX,
                            y: selection.minY * scaleY,
                            width: selection.width * scaleX,
                            height: selection.height * scaleY).integral
        guard let cropped = cg.cropping(to: scaled) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    @MainActor
    private func runTutor(crop: UIImage, lesson: Lesson, pageNumber: Int, requestID: UUID) async {
        defer {
            if tutorRequestID == requestID {
                tutorBusy = false
                tutorTask = nil
            }
        }

        // 1. OCR：先看圈到的是什么字，顺便决定要不要花钱看图
        let ocr = await OCRService.recognize(in: crop)
        guard !Task.isCancelled, tutorRequestID == requestID,
              self.lesson?.coursewareFileName == lesson.coursewareFileName else { return }
        let looksFormula = TutorChain.looksLikeFormulaOrDiagram(ocr.text)
        let needsVision = TutorChain.shouldUseVision(
            ocrConfidence: ocr.confidence,
            hasFormulaOrDiagram: looksFormula,
            hasImage: true
        )

        let prompt = TutorChain.buildPrompt(
            subject: settings.courseTopic,
            selectionText: ocr.text,
            frameworkSummary: lesson.notes?.framework.bigPicture ?? "",
            pageIndex: pageNumber
        )

        do {
            let answer: String
            var visionUsed = false

            if needsVision && settings.hasVisionConfiguration {
                let vision = VisionAIService(baseURL: settings.visionBaseURL,
                                             apiKey: settings.visionAPIKey,
                                             model: settings.visionModel)
                answer = try await vision.ask(
                    prompt: prompt,
                    imageJPEG: VisionAIService.jpegData(from: crop))
                visionUsed = true
            } else if !ocr.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 文字够清楚，用便宜的文本模型
                let text = AIService(settings: settings)
                answer = try await text.complete(messages: [
                    ChatMessage(role: "system", content: prompt.system),
                    ChatMessage(role: "user", content: prompt.user)
                ])
            } else if settings.hasVisionConfiguration {
                let vision = VisionAIService(baseURL: settings.visionBaseURL,
                                             apiKey: settings.visionAPIKey,
                                             model: settings.visionModel)
                answer = try await vision.ask(
                    prompt: prompt,
                    imageJPEG: VisionAIService.jpegData(from: crop))
                visionUsed = true
            } else {
                tutorError = "这块没识别出文字（可能是图表或公式）。去「设置 → 视觉模型」填个 Key 就能看懂图。"
                return
            }

            // 页码来自圈选时的快照；旧请求或已更换课件的结果不能写进当前记录。
            guard !Task.isCancelled, tutorRequestID == requestID,
                  var updated = self.lesson,
                  updated.coursewareFileName == lesson.coursewareFileName else { return }
            let parsed = TutorChain.parse(answer)
            tutorSteps = parsed.steps
            tutorFollowUp = parsed.followUp
            usedVision = visionUsed

            // 请求期间可能已保存批注，追加讲解时要保留最新课程内容。
            var entry = TutorEntry()
            entry.pageIndex = pageNumber
            entry.selectionText = ocr.text
            entry.steps = parsed.steps
            entry.followUpQuestion = parsed.followUp
            entry.usedVision = visionUsed
            if let jpeg = VisionAIService.jpegData(from: crop, maxEdge: 900) {
                entry.imageFileName = try? store.saveTutorImage(jpeg)
            }
            updated.tutorLog.insert(entry, at: 0)
            store.save(updated)
        } catch {
            guard !Task.isCancelled, tutorRequestID == requestID else { return }
            tutorError = friendlyErrorMessage(error)
        }
    }

    private var tutorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selectedImage {
                        Text("本次圈选").font(.caption).foregroundStyle(.secondary)
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .accessibilityLabel("发送给讲解模型的圈选截图")
                    }
                    if tutorBusy {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在看这块内容…").font(.callout)
                        }
                        Text("先用文字识别，认不准才让视觉模型看图，能省就省。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let tutorError {
                        Text(tutorError)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    ForEach(tutorSteps) { step in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.title)
                                .font(.subheadline.bold())
                                .foregroundStyle(.indigo)
                            Text(step.body).font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if !tutorFollowUp.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("检验一下", systemImage: "questionmark.circle")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            Text(tutorFollowUp).font(.callout)
                            Text("先自己想，想不出来再回去看上面的讲解。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if !tutorSteps.isEmpty && !usedVision {
                        Text("这次用的是文字模型（便宜）。遇到图表或公式会自动切换到视觉模型。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(18)
            }
            .navigationTitle("讲解")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showTutorSheet = false }
                }
            }
        }
    }
}

/// 文字识别。用 Vision 框架，设备端跑，不联网、不花钱。
enum OCRService {
    struct Result {
        var text: String
        /// 0–1，识别行置信度的平均值；低就说明这块不适合只靠文字
        var confidence: Double
    }

    static func recognize(in image: UIImage) async -> Result {
        guard let cg = image.cgImage else { return Result(text: "", confidence: 0) }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                var lines: [String] = []
                var total: Float = 0
                var count = 0
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    lines.append(candidate.string)
                    total += candidate.confidence
                    count += 1
                }
                let avg = count > 0 ? Double(total) / Double(count) : 0
                continuation.resume(returning: Result(
                    text: lines.joined(separator: "\n"),
                    confidence: avg))
            }
            // 中英韩都开：课件常常是外语
            request.recognitionLanguages = ["zh-Hans", "en-US", "ko-KR"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: Result(text: "", confidence: 0))
                }
            }
        }
    }
}
