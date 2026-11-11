import Foundation
import UIKit

enum VisionError: LocalizedError {
    case missingKey
    case badURL
    case http(Int, String)
    case empty
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有填视觉模型的 Key。去「设置 → 视觉模型」填一个，只有看图表/公式时才会用到。"
        case .badURL:
            return "视觉模型的地址不对，检查「设置」里的 Base URL。"
        case .http(let code, let body):
            return "视觉模型返回 \(code)：\(body.prefix(160))"
        case .empty:
            return "视觉模型没有返回内容。"
        case .imageTooLarge:
            return "圈选区域太大，压缩后仍超过限制。缩小圈选范围再试。"
        }
    }
}

/// 能发图片的 OpenAI 兼容客户端。
///
/// 为什么单独一个类：文本模型和视觉模型通常是两套 Key、两个模型名，
/// 而且视觉按图片计费，贵得多。分开写才能让调用方明确决定「这次值不值得看图」。
///
/// 不依赖 AppSettings，方便单独测试，也避免和主 AI 服务耦合。
struct VisionAIService {
    let baseURL: String
    let apiKey: String
    let model: String

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpoint() throws -> URL {
        guard var url = URL(string: baseURL), url.scheme != nil else { throw VisionError.badURL }
        if !url.path.hasSuffix("/chat/completions") {
            url = url.appendingPathComponent("chat/completions")
        }
        return url
    }

    /// 发一次请求。imageJPEG 为 nil 时退化成纯文字请求。
    func ask(prompt: (system: String, user: String),
             imageJPEG: Data?) async throws -> String {
        guard !apiKey.isEmpty else { throw VisionError.missingKey }

        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        // 视觉模型处理图片慢，给足时间；但也不能无限等，切屏时会被系统掐断
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // OpenAI 兼容的多模态格式：content 是数组，元素可以是 text 或 image_url
        var userContent: [[String: Any]] = [
            ["type": "text", "text": prompt.user]
        ]
        if let imageJPEG {
            guard let b64 = Self.jpegBase64(imageJPEG) else { throw VisionError.imageTooLarge }
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(b64)"]
            ])
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": userContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 和主服务一样：切屏/锁屏造成的瞬时断网值得重试
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await perform(request)
            } catch let error as VisionError {
                throw error
            } catch {
                lastError = error
                guard isRetryableNetworkError(error), attempt < 2 else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 800_000_000)
            }
        }
        throw lastError ?? VisionError.empty
    }

    private func perform(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            throw VisionError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw VisionError.empty
        }
        return content
    }

    /// 已经在渲染时压缩过，这里只做 base64；
    /// 再兜一层大小检查，避免把几百 KB 的图当成几 MB 发出去。
    static func jpegBase64(_ data: Data) -> String? {
        guard data.count <= 1_500_000 else { return nil }
        return data.base64EncodedString()
    }

    /// 把 UIImage 压到长边不超过 maxEdge，返回 JPEG Data。
    /// 视觉模型对 1400px 已经足够，再大只是多花钱。
    static func jpegData(from image: UIImage,
                         maxEdge: CGFloat = 1400,
                         quality: CGFloat = 0.7) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        // 用 UIGraphicsImageRenderer 而不是 UIGraphicsBeginImageContext：
        // 前者会跟随设备 scale，文字在 Retina 上不会糊。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
