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
        context.coordinator.scrollView = scroll
        context.coordinator.installToolPicker(for: canvas)
        context.coordinator.apply(tool: tool, to: canvas)
        context.coordinator.installSelectionGesture(on: scroll)

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
        /// 外层滚动容器。圈选时靠它关掉手指输入，把触摸让给选择框
        var scrollView: UIScrollView?
        private var tool: CanvasTool
        private var toolPicker: PKToolPicker?

        /// 手指拖出来的选择框。没有 Apple Pencil 时全靠它。
        private var selectionLayer: CAShapeLayer?
        private var dragStart: CGPoint?
        /// 手指拖动时用来区分「点一下」和「拖一个框」
        private var dragMoved = false

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

        /// 切换工具。
        ///
        /// 两个坑都在这里踩过：
        /// 1. 以前在圈选模式把 drawingGestureRecognizer 关掉，导致什么也画不出来，
        ///    整个圈选功能是死的。
        /// 2. 只靠 drawingPolicy = .anyInput 也不行：画布会把手指标手势全部吃掉，
        ///    选择框的 pan 根本收不到触摸。
        /// 所以圈选时把策略切回 .pencilOnly：手指穿透给选择框，笔仍然能画。
        func apply(tool: CanvasTool, to canvas: PKCanvasView?) {
            guard let canvas else { return }
            self.tool = tool
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
                // 手指交给选择框；有笔的话仍然能直接圈
                canvas.drawingPolicy = .pencilOnly
                canvas.tool = PKInkingTool(.pen, color: .systemYellow, width: 3)
            }
        }

        // MARK: - 手指圈选

        /// 圈选模式下接住拖动。挂在外层 scroll 上，这样即使点在页面空白处也能起框。
        func installSelectionGesture(on view: UIView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            // 不能抢缩放：双指交给 scroll 自己处理
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard tool == .select, let container else { return }
            let point = gesture.location(in: container)

            switch gesture.state {
            case .began:
                // 新的一次圈选：把上一个框清掉，否则会越积越多
                clearSelection()
                dragStart = point
                dragMoved = false
                showSelection(from: point, to: point)

            case .changed:
                guard let start = dragStart else { return }
                if hypot(point.x - start.x, point.y - start.y) > 6 {
                    dragMoved = true
                }
                showSelection(from: start, to: point)

            case .ended, .cancelled:
                guard let start = dragStart else { return }
                dragStart = nil
                let rect = CGRect(x: min(start.x, point.x),
                                  y: min(start.y, point.y),
                                  width: abs(point.x - start.x),
                                  height: abs(point.y - start.y))

                // 只点了一下没拖动：给一个默认大小，方便快速提问
                if !dragMoved || rect.width < 24 || rect.height < 24 {
                    let side: CGFloat = 220
                    let fallback = CGRect(
                        x: max(0, min(point.x - side / 2, canvasSize.width - side)),
                        y: max(0, min(point.y - side / 2, canvasSize.height - side)),
                        width: side, height: side)
                    keepSelection(fallback)
                    onSelection?(fallback.insetBy(dx: -6, dy: -6))
                } else {
                    keepSelection(rect)
                    onSelection?(rect.insetBy(dx: -6, dy: -6))
                }

            default:
                break
            }
        }

        private var canvasSize: CGSize {
            container?.bounds.size ?? .zero
        }

        private func showSelection(from: CGPoint, to: CGPoint) {
            guard let container else { return }
            let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                              width: abs(to.x - from.x), height: abs(to.y - from.y))
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

        /// 松手后保留框，让学生看得见自己圈了哪块
        private func keepSelection(_ rect: CGRect) {
            guard let container else { return }
            let layer = CAShapeLayer()
            layer.strokeColor = UIColor.systemIndigo.cgColor
            layer.fillColor = UIColor.systemIndigo.withAlphaComponent(0.10).cgColor
            layer.lineWidth = 2
            layer.path = UIBezierPath(rect: rect).cgPath
            container.layer.addSublayer(layer)
            selectionLayer = layer
        }

        func clearSelection() {
            selectionLayer?.removeFromSuperlayer()
            selectionLayer = nil
        }

        // MARK: - PKCanvasViewDelegate

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard tool == .select else { return }
            // 兜底：如果有人在圈选模式下用笔画了一圈，也按包围盒处理
            guard let last = canvasView.drawing.strokes.last, !last.path.isEmpty else { return }
            let rect = last.renderBounds.insetBy(dx: -8, dy: -8)
            keepSelection(rect)
            onSelection?(rect)
        }
    }
}

extension PencilCanvasView.Coordinator: UIGestureRecognizerDelegate {
    /// 选择框的 pan 只接单指，而且只在圈选模式下活。
    /// 双指缩放交给 scroll 自己的手势，两者不冲突。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 允许和 scroll 共存；返回 false 会让单指拖动被 scroll 吃掉
        return true
    }

    /// 只在圈选模式下才让选择框手势开始，避免影响其他工具
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return tool == .select
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
