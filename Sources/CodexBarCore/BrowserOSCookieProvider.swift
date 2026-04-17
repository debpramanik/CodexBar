import Foundation

#if os(macOS)
import SweetCookieKit

/// Cookie provider that fetches cookies from BrowserOS MCP server
/// instead of reading from Chrome's Keychain-encrypted cookie store.
public enum BrowserOSCookieProvider {
    /// Configurable MCP endpoint. Defaults to `http://127.0.0.1:9001/mcp`.
    /// Set this at app startup to override the default.
    nonisolated(unsafe) public static var endpoint = "http://127.0.0.1:9001/mcp"
    private static let log = CodexBarLog.logger(LogCategories.browserCookieGate)

    /// Check if BrowserOS MCP server is reachable
    public static func isAvailable(timeout: TimeInterval = 2.0, endpoint: String? = nil) -> Bool {
        let urlEndpoint = endpoint ?? Self.endpoint
        guard let url = URL(string: urlEndpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // MCP HTTP+SSE transport requires Accept: text/event-stream header
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        // Send a minimal JSON-RPC ping
        let body = #"{"jsonrpc":"2.0","method":"tools/list","id":1}"#
        request.httpBody = body.data(using: .utf8)

        class ResultBox: @unchecked Sendable {
            var value = false
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let httpResponse = response as? HTTPURLResponse {
                // 2xx/3xx/4xx all mean the server is reachable and processing requests.
                // Only 5xx or network errors indicate unavailability.
                if httpResponse.statusCode < 500 {
                    box.value = true
                    log.debug("BrowserOS MCP is available at \(urlEndpoint) (status: \(httpResponse.statusCode))")
                } else {
                    log.debug("BrowserOS MCP returned server error: \(httpResponse.statusCode)")
                }
            } else if let error {
                // Connection refused / timeout — server not reachable
                log.debug("BrowserOS MCP not available: \(error.localizedDescription)")
            } else {
                log.debug("BrowserOS MCP not available: no response")
            }
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 1.0)
        return box.value
    }
    
    /// Fetch cookies from BrowserOS for the given domains
    public static func fetchCookies(
        for domains: [String] = [],
        endpoint: String? = nil
    ) throws -> [BrowserCookieRecord] {
        let resolvedEndpoint = endpoint ?? Self.endpoint
        guard let url = URL(string: resolvedEndpoint) else {
            throw BrowserCookieError.notFound(browser: .browseros, details: "Invalid BrowserOS endpoint")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10.0

        let rpcBody = #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"get_cookies","arguments":{}},"id":1}"#
        request.httpBody = rpcBody.data(using: .utf8)

        class ResultBox: @unchecked Sendable {
            var value: Result<[BrowserCookieRecord], Error>?
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                box.value = .failure(
                    BrowserCookieError.loadFailed(browser: .browseros, details: error.localizedDescription))
                return
            }

            guard let data = data else {
                box.value = .failure(
                    BrowserCookieError.loadFailed(browser: .browseros, details: "Empty response from BrowserOS"))
                return
            }

            do {
                let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let rpcResult = jsonResponse?["result"] as? [String: Any],
                      let content = rpcResult["content"] as? [[String: Any]] else {
                    box.value = .success([])
                    return
                }

                var records: [BrowserCookieRecord] = []
                for cookieDict in content {
                    guard let name = cookieDict["name"] as? String,
                          let value = cookieDict["value"] as? String,
                          let domain = cookieDict["domain"] as? String else {
                        continue
                    }

                    let expires = (cookieDict["expires"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
                    let secure = (cookieDict["secure"] as? Bool) ?? false
                    let httpOnly = (cookieDict["httpOnly"] as? Bool) ?? false

                    records.append(BrowserCookieRecord(
                        domain: domain.hasPrefix(".") ? String(domain.dropFirst()) : domain,
                        name: name,
                        path: (cookieDict["path"] as? String) ?? "/",
                        value: value,
                        expires: expires,
                        isSecure: secure,
                        isHTTPOnly: httpOnly
                    ))
                }

                box.value = .success(records)
            } catch {
                box.value = .failure(
                    BrowserCookieError.loadFailed(browser: .browseros, details: error.localizedDescription))
            }
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + 15.0)
        return try (box.value ?? .failure(
            BrowserCookieError.loadFailed(browser: .browseros, details: "Request timed out")
        )).get()
    }
    
    /// Build BrowserCookieStoreRecords from BrowserOS cookies
    public static func fetchRecords(
        for query: BrowserCookieQuery = BrowserCookieQuery(),
        logger: ((String) -> Void)? = nil
    ) throws -> [BrowserCookieStoreRecords] {
        let records = try fetchCookies(for: query.domains)
        logger?("BrowserOS: fetched \(records.count) cookie records")
        
        let store = BrowserCookieStore(
            browser: .browseros,
            profile: BrowserProfile(id: "browseros", name: "BrowserOS"),
            kind: .primary,
            label: "BrowserOS MCP",
            databaseURL: URL(string: Self.endpoint)
        )
        
        return [BrowserCookieStoreRecords(store: store, records: records)]
    }
}

#else
public enum BrowserOSCookieProvider {
    nonisolated(unsafe) public static var endpoint = "http://127.0.0.1:9001/mcp"
    public static func isAvailable(timeout: TimeInterval = 2.0, endpoint: String? = nil) -> Bool { false }
    public static func fetchCookies(
        for domains: [String] = [],
        endpoint: String? = nil
    ) throws -> [BrowserCookieRecord] { [] }
    public static func fetchRecords(
        for query: BrowserCookieQuery = BrowserCookieQuery(),
        logger: ((String) -> Void)? = nil
    ) throws -> [BrowserCookieStoreRecords] { [] }
}
#endif
