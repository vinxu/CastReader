import Foundation
import PDFKit
let p=PDFDocument(url:URL(fileURLWithPath:"reports/ios-28-languages-20261008/long-fixtures/cs.pdf"))!.page(at:9)!
let ns=p.string! as NSString
let start=ns.range(of:"Babička měla").location
let selection=p.selection(for:NSRange(location:start,length:240))!
for (j,line) in selection.selectionsByLine().enumerated() {
 var all=CGRect.null, ink=CGRect.null, abnormal:[String]=[]
 for n in 0..<line.numberOfTextRanges(on:p) {
  let r=line.range(at:n,on:p)
  print("lineText",(line.string ?? "").debugDescription,"rangeText",ns.substring(with:r).debugDescription)
  for i in r.location..<NSMaxRange(r) {
   let rect=p.characterBounds(at:i);all=all.union(rect)
   let c=ns.substring(with:NSRange(location:i,length:1))
   if !c.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {ink=ink.union(rect)}
   if rect.height>25 {abnormal.append("\(c.debugDescription):\(Int(rect.height))")}
  }
 }
 print(j,"selected",line.bounds(for:p).height,"all",all.height,"ink",ink.height,"wideGlyphs",abnormal.prefix(8))
}
