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
        container.addSubview(canvas)

        context.coordinator.container = container
        context.coordinator.imageView = imageView
        context.coordinator.canvas = canvas
        context.coordinator.scrollView = scroll
        context.coordinator.installToolPicker(for: canvas)
        context.coordinator.installSelectionGesture(on: scroll)
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
        if coordinator.imageView?.image !== pageImage {
            coordinator.clearSelection()
            coordinator.imageView?.image = pageImage
        }

        // 页面切换时画布尺寸可能变，这里同步一下，避免旧笔画错位
        if coordinator.container?.bounds.size != canvasSize,
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

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var container: UIView?
        var imageView: UIImageView?
        var canvas: PKCanvasView?
        var onSelection: ((CGRect) -> Void)?
        weak var scrollView: UIScrollView?
        private var tool: CanvasTool
        private var toolPicker: PKToolPicker?
        private weak var selectionGesture: UIPanGestureRecognizer?
        private var normalPanTouchCount = 1

        /// 手指拖出来的选择框。没有 Apple Pencil 时全靠它。
        private var selectionLayer: CAShapeLayer?
        private var dragStart: CGPoint?

        init(tool: CanvasTool, onSelection: ((CGRect) -> Void)?) {
            self.tool = tool
            self.onSelection = onSelection
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

        func installToolPicker(for canvas: PKCanvasView) {
            // 应用里已经有自己的工具条（铅笔/荧光笔/橡皮/圈选）。
            // 系统 PKToolPicker 在没有 Apple Pencil 的 iPad 上会悬在屏幕底部遮内容，
            // 而且和我们的工具条重复，所以不默认显示。
            let picker = PKToolPicker()
            picker.addObserver(canvas)
            picker.setVisible(false, forFirstResponder: canvas)
            // 仍然让画布成为第一响应者，笔的压感和倾斜才正常
            canvas.becomeFirstResponder()
            toolPicker = picker
        }

        func apply(tool: CanvasTool, to canvas: PKCanvasView?) {
            guard let canvas else { return }
            if self.tool != tool {
                dragStart = nil
                clearSelection()
            }
            self.tool = tool
            let isSelecting = tool == .select
            canvas.isUserInteractionEnabled = !isSelecting
            selectionGesture?.isEnabled = isSelecting
            scrollView?.panGestureRecognizer.minimumNumberOfTouches = isSelecting ? 2 : normalPanTouchCount
            switch tool {
            case .pen:
                canvas.drawingPolicy = .anyInput
                canvas.tool = PKInkingTool(.pen, color: .systemYellow, width: 3)
            case .highlighter:
                canvas.drawingPolicy = .anyInput
                let color = UIColor.systemYellow.withAlphaComponent(0.35)
                canvas.tool = PKInkingTool(.marker, color: color, width: 18)
            case .eraser:
                canvas.drawingPolicy = .anyInput
                canvas.tool = PKEraserTool(.bitmap)
            case .select:
                break
            }
        }

        // MARK: - 手指圈选

        func installSelectionGesture(on scroll: UIScrollView) {
            normalPanTouchCount = scroll.panGestureRecognizer.minimumNumberOfTouches
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                     NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            pan.delegate = self
            scroll.addGestureRecognizer(pan)
            selectionGesture = pan
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard tool == .select, let container else { return }
            let point = gesture.location(in: container)

            switch gesture.state {
            case .began:
                clearSelection()
                // 手势越过识别阈值才进入 .began，减掉位移以恢复手指按下的位置。
                let translation = gesture.translation(in: container)
                let start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
                guard container.bounds.contains(start) else { return }
                dragStart = start
                showSelection(selectionRect(from: start, to: point, in: container.bounds))

            case .changed:
                guard let start = dragStart else { return }
                showSelection(selectionRect(from: start, to: point, in: container.bounds))

            case .ended:
                guard let start = dragStart else { return }
                dragStart = nil
                let rect = selectionRect(from: start, to: point, in: container.bounds)
                guard rect.width >= 8, rect.height >= 8 else {
                    clearSelection()
                    return
                }
                showSelection(rect)
                selectionLayer?.lineDashPattern = nil
                onSelection?(rect.insetBy(dx: -6, dy: -6).intersection(container.bounds))

            case .cancelled, .failed:
                dragStart = nil
                clearSelection()

            default:
                break
            }
        }

        private func selectionRect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
            CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                   width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        }

        private func showSelection(_ rect: CGRect) {
            guard let container else { return }
            let path = UIBezierPath(rect: rect)

            let layer: CAShapeLayer
            if let existing = selectionLayer {
                layer = existing
            } else {
                layer = CAShapeLayer()
                layer.strokeColor = UIColor.systemIndigo.cgColor
                layer.fillColor = UIColor.systemIndigo.withAlphaComponent(0.12).cgColor
                layer.lineWidth = 2
                layer.lineDashPattern = [6, 4]
                container.layer.addSublayer(layer)
                selectionLayer = layer
            }
            layer.path = path.cgPath
        }

        func clearSelection() {
            dragStart = nil
            selectionLayer?.removeFromSuperlayer()
            selectionLayer = nil
        }
    }
}

extension PencilCanvasView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        tool == .select && gestureRecognizer.numberOfTouches == 1
    }
}

/// 给 SwiftUI 用的画布句柄：读写笔画、清空。
/// 页面切换时用它把上一页的笔画存回去、再把新页的载入。
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
