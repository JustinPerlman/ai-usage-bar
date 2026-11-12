import Foundation

// Usage responses and authentication stay out of persistent session stores.
func usageSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    return configuration
}

final class UsageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        // Never forward an authenticated usage request to a redirected URL.
        nil
    }
}

let usageSession = URLSession(configuration: usageSessionConfiguration(),
                              delegate: UsageRedirectPolicy(), delegateQueue: nil)
