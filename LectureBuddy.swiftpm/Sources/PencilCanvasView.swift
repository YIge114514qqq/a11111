import SwiftUI
import PencilKit
import UIKit

/// 课件 + 手写批注的叠加视图。
///
/// 【最关键的坑】批注必须和内容严格对齐。
/// 常见错误做法是「PDF 放在一个 ScrollView，PencilKit 放在另一个 ScrollView」，
/// 两边缩放系数不同，放大后笔迹就和文字错位。
///
/// 这里的做法：外层只有一个 UIScrollView 负责缩放平移，
/// 里面放一个固定尺寸的容器（宽高 = 渲染尺寸），
/// PDF 图层和 PKCanvasView 都是这个容器的子视图，尺寸完全一致。
/// 这样缩放时两者一起被 transform，天然对齐。
struct PencilCanvasView: UIViewRepresentable {
    /// 已渲染好的页面内容（PDF 页或图片），尺寸必须等于 canvasSize
    let pageImage: UIImage?
    /// 逻辑画布尺寸（pt）。PDF 按这个尺寸渲染，批注坐标系也用它
    let canvasSize: CGSize
    /// 当前工具
    let tool: CanvasTool
    /// 退出圈选模式后要把选中的矩形回调出去
    var onSelection: ((CGRect) -> Void)?
    /// 给外部一个句柄，用来导出/导入笔画
    @Binding var canvasHandle: CanvasHandle?

    enum CanvasTool: Equatable {
        case pen, highlighter, eraser, select
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 0.5
        scroll.maximumZoomScale = 5.0
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator

        let container = UIView(frame: CGRect(origin: .zero, size: canvasSize))
        container.backgroundColor = .clear
        scroll.addSubview(container)
        scroll.contentSize = canvasSize

        // 1. 页面内容层
        let imageView = UIImageView(frame: CGRect(origin: .zero, size: canvasSize))
        imageView.image = pageImage
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        container.addSubview(imageView)

        // 2. 批注层：和内容层同尺寸同位置
        let canvas = PKCanvasView(frame: CGRect(origin: .zero, size: canvasSize))
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput   // 允许手指，不只 Apple Pencil
        canvas.delegate = context.coordinator
        container.addSubview(canvas)

        context.coordinator.container = container
        context.coordinator.imageView = imageView
        context.coordinator.canvas = canvas
        context.coordinator.installToolPicker(for: canvas)
        context.coordinator.apply(tool: tool, to: canvas)

        // 把句柄给出去，外部通过它读写笔画
        DispatchQueue.main.async {
            canvasHandle = CanvasHandle(canvas: canvas)
        }
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelection = onSelection
        coordinator.apply(tool: tool, to: coordinator.canvas)
        coordinator.imageView?.image = pageImage

        // 页面切换时画布尺寸可能变，这里同步一下，避免旧笔画错位
        if coordinator.container?.frame.size != canvasSize,
           let container = coordinator.container,
           let canvas = coordinator.canvas,
           let imageView = coordinator.imageView {
            container.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            imageView.frame = CGRect(origin: .zero, size: canvasSize)
            scroll.contentSize = canvasSize
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tool: tool, onSelection: onSelection)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, PKCanvasViewDelegate {
        var container: UIView?
        var imageView: UIImageView?
        var canvas: PKCanvasView?
        var onSelection: ((CGRect) -> Void)?
        private var tool: CanvasTool
        private var toolPicker: PKToolPicker?
        /// 圈选模式下，一笔画完后记录起点，用来算包围盒
        private var selectStart: CGPoint?

        init(tool: CanvasTool, onSelection: ((CGRect) -> Void)?) {
            self.tool = tool
            self.onSelection = onSelection
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func installToolPicker(for canvas: PKCanvasView) {
            let picker = PKToolPicker()
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
            toolPicker = picker
        }

        func apply(tool: CanvasTool, to canvas: PKCanvasView?) {
            guard let canvas else { return }
            self.tool = tool
            switch tool {
            case .pen:
                canvas.tool = PKInkingTool(.pen, color: .systemYellow, width: 3)
                canvas.drawingGestureRecognizer.isEnabled = true
            case .highlighter:
                // 荧光笔用一个半透明色，能透出下面的字
                let color = UIColor.systemYellow.withAlphaComponent(0.35)
                canvas.tool = PKInkingTool(.marker, color: color, width: 18)
                canvas.drawingGestureRecognizer.isEnabled = true
            case .eraser:
                canvas.tool = PKEraserTool(.bitmap)
                canvas.drawingGestureRecognizer.isEnabled = true
            case .select:
                // 圈选时自己处理手势：先关掉画布手势，避免和选择框冲突
                canvas.drawingGestureRecognizer.isEnabled = false
            }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard tool == .select else { return }
            let strokes = canvasView.drawing.strokes
            guard let last = strokes.last, !last.path.isEmpty else { return }
            let rect = last.renderBounds.insetBy(dx: -8, dy: -8)
            onSelection?(rect)
        }
    }
}

/// 给 SwiftUI 用的画布句柄：读写笔画、清空。
struct CanvasHandle {
    weak var canvas: PKCanvasView?

    func drawingData() -> Data? {
        canvas?.drawing.dataRepresentation()
    }

    func loadDrawing(_ data: Data?) {
        guard let canvas else { return }
        if let data, let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        } else {
            canvas.drawing = PKDrawing()
        }
    }

    func clear() {
        canvas?.drawing = PKDrawing()
    }
}
