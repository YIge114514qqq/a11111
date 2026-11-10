import Foundation

/// 把系统网络错误翻译成人能看懂的一句话。
/// 用户看到 "The network connection was lost." 完全不知道下一步该干什么。
///
/// 单独放在一个文件里，不依赖 AppSettings / URLSession，
/// 这样 CI 可以用 swiftc 单独编译它做测试。
func friendlyErrorMessage(_ error: Error) -> String {
    if (error as NSError).domain != NSURLErrorDomain,
       let localized = (error as? LocalizedError)?.errorDescription {
        return localized
    }
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else {
        return nsError.localizedDescription
    }
    switch nsError.code {
    case NSURLErrorNetworkConnectionLost:
        return "连接中途断了。切到别的 App、锁屏或者网络切换都会这样。请回到 App 保持前台，再点一次生成。"
    case NSURLErrorTimedOut:
        return "请求超时。课堂内容较长时第一次生成会慢一些，保持前台再试一次。"
    case NSURLErrorNotConnectedToInternet:
        return "设备没有连网。检查 Wi-Fi 或蜂窝网络后再试。"
    case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
        return "连不上服务器。检查「设置」里的 Base URL 是否写对，以及网络是否能访问该域名。"
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
        return "HTTPS 证书校验失败。如果用了代理或自建中转，需要换成受信任的证书。"
    default:
        return "网络出错（\(nsError.code)）：\(nsError.localizedDescription)"
    }
}

/// 是否值得重试：切屏、超时、瞬时断网这类重试一次大概率能过；
/// 401/400 这类服务端明确拒绝的、以及证书问题重试没用。
func isRetryableNetworkError(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return false }
    return [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorSecureConnectionFailed
    ].contains(nsError.code)
}
