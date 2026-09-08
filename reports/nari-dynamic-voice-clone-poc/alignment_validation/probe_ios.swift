import Foundation

@main struct CompatibilityProbe {
    static func main() throws {
        let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let rows = try JSONSerialization.jsonObject(with: input) as! [[String:Any]]
        var results = [[String:Any]]()
        for row in rows {
            let wire = row["response"] as! [String:Any]
            let data = try JSONSerialization.data(withJSONObject: wire)
            let response = try JSONDecoder().decode(TTSResponse.self, from: data)
            precondition(response.audio == wire["audio"] as? String)
            let timestamps = TTSHighlightPolicy.displayTimestamps(response.safeTimestamps, language:row["language"] as! String)
            let reliable = TTSTimestampQuality.hasReliableWordGranularity(
                text:row["text"] as! String, timestamps:timestamps, duration:row["duration"] as! Double)
            results.append(["id":row["id"]!,"accepted":true,"timestamps":timestamps.count,"wordQuality":reliable])
        }
        let output = try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
        try output.write(to: URL(fileURLWithPath:CommandLine.arguments[2]))
        print("iOS actual decoder/policy replay: \(results.count) cases")
    }
}
