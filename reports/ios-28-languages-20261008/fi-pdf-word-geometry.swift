import Foundation
import PDFKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("reports/ios-28-languages-20261008")
let pdf = PDFDocument(url: root.appendingPathComponent("long-fixtures/fi.pdf"))!
let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fi-pdf-word-probe.json"))) as! [String: Any]
let words = (probe["timestamps"] as! [[String: Any]]).map { $0["word"] as! String }
var results: [[String: Any]] = []
for i in 0..<pdf.pageCount {
 let page = pdf.page(at:i)!, text = (pdf.page(at:i)!.string ?? "") as NSString
 let start = text.range(of:"Konrad Gesner")
 guard start.location != NSNotFound else {continue}
 var cursor = start.location
 for word in words {
  let range=text.range(of:word, options:[.caseInsensitive],range:NSRange(location:cursor,length:text.length-cursor))
  if range.location == NSNotFound {results.append(["word":word,"found":false]);continue}
  let rect=pdf.selection(from:page,atCharacterIndex:range.location,to:page,atCharacterIndex:NSMaxRange(range))?.bounds(for:page) ?? .null
  results.append(["word":word,"found":true,"x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height])
  cursor=NSMaxRange(range)
 }
}
let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
try data.write(to:root.appendingPathComponent("fi-pdf-word-geometry.json"))
print("Word matches: \(results.filter { $0["found"] as? Bool == true }.count)/\(words.count)")
