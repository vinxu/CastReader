import Foundation
import PDFKit
import AppKit
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("reports/ios-28-languages-20261008")
let doc=PDFDocument(url:root.appendingPathComponent("long-fixtures/cs.pdf"))!
var rows:[[String:Any]]=[]
for i in 0..<doc.pageCount {
 let p=doc.page(at:i)!, text=(p.string ?? "") as NSString
 let range=text.range(of:"Dávno, dávno")
 guard range.location != NSNotFound else {continue}
 let r=NSRange(location:range.location,length:5)
 let bounds=p.selection(for:r)!.bounds(for:p)
 let font=p.attributedString?.attribute(.font,at:r.location,effectiveRange:nil) as? NSFont
 rows.append(["page":i,"range":NSStringFromRange(r),"selectionBounds":NSStringFromRect(bounds),"firstCharacterBounds":NSStringFromRect(p.characterBounds(at:r.location)),"fontSize":font?.pointSize ?? -1,"fontAscender":font?.ascender ?? -1,"fontDescender":font?.descender ?? -1])
 if rows.count>=3 {break}
}
let data=try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]);try data.write(to:root.appendingPathComponent("cs-pdf-source-geometry.json"));print(String(data:data,encoding:.utf8)!)
