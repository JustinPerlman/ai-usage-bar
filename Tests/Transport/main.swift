import Foundation

let configuration = usageSessionConfiguration()
precondition(configuration.urlCache == nil, "usage responses must not be cached")
precondition(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
precondition(configuration.urlCredentialStorage == nil)
precondition(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)

Task {
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let source = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    let task = session.dataTask(with: source) // Deliberately never resumed.
    for target in [source, URL(string: "https://example.invalid/collect")!, URL(string: "http://example.invalid/collect")!] {
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": target.absoluteString])!
        let redirected = await UsageRedirectPolicy().urlSession(session, task: task,
            willPerformHTTPRedirection: response, newRequest: URLRequest(url: target))
        precondition(redirected == nil, "authenticated redirects must be rejected")
    }
    print("Transport checks passed: no persistent stores; same-host, cross-host and HTTP redirects rejected")
    exit(0)
}
dispatchMain()
