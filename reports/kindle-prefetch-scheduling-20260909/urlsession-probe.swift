import Foundation
import Dispatch

final class Metrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let data: [[String: Any]] = metrics.transactionMetrics.map { m in
            var v: [String: Any] = ["protocol": m.networkProtocolName ?? "unknown", "reusedConnection": m.isReusedConnection]
            func duration(_ key: String, _ a: Date?, _ b: Date?) { if let a, let b { v[key] = b.timeIntervalSince(a) } }
            duration("fetchToRequest", m.fetchStartDate, m.requestStartDate)
            duration("requestToFirstByte", m.requestStartDate, m.responseStartDate)
            duration("bodyDownload", m.responseStartDate, m.responseEndDate)
            return v
        }
        lock.lock(); values = ["taskSeconds": metrics.taskInterval.duration, "transactions": data]; lock.unlock()
    }
    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return values }
}
let inputURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().appendingPathComponent("probe-input.json")
let body = try Data(contentsOf: inputURL)
let config = URLSessionConfiguration.ephemeral
config.httpCookieStorage = nil
config.httpShouldSetCookies = false
config.urlCredentialStorage = nil
config.timeoutIntervalForRequest = 35
config.timeoutIntervalForResource = 40
let session = URLSession(configuration: config)
func probe(_ label: String) async -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.castreader.cn/api/captioned_speech_partly")!)
    request.httpMethod = "POST"; request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let id = "kindle-stall-diagnosis-" + UUID().uuidString.lowercased()
    request.setValue(id, forHTTPHeaderField: "X-Request-ID")
    let started = Date(); let metrics = Metrics()
    do {
        let (data,response) = try await session.data(for: request, delegate: metrics)
        let elapsed = Date().timeIntervalSince(started)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ["label":label,"requestId":id,"started":ISO8601DateFormatter().string(from: started),"elapsedSeconds":elapsed,"bytes":data.count,"status":(response as? HTTPURLResponse)?.statusCode ?? 0,"hasAudio":(json?["audio"] as? String)?.isEmpty == false,"metrics":metrics.snapshot()]
    } catch { return ["label":label,"requestId":id,"elapsedSeconds":Date().timeIntervalSince(started),"errorType":String(describing:type(of:error))] }
}
func output(_ v: Any) { let data = try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]); print(String(data: data, encoding:.utf8)!); fflush(stdout) }
Task {
    output(["kind":"config","httpMaximumConnectionsPerHost":config.httpMaximumConnectionsPerHost,"note":"Mac diagnostic; same session API as app; not an iPhone measurement" ])
    output(await probe("serial-warmup"))
    await withTaskGroup(of: [String: Any].self) { group in
        for i in 1...3 { group.addTask { await probe("burst-3-\(i)") } }
        for await value in group { output(value) }
    }
    session.invalidateAndCancel()
    exit(0)
}
dispatchMain()
