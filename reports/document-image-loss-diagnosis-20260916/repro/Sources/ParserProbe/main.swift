import Foundation

enum ReadingParagraphType: Equatable {
    case paragraph, heading(Int), blockquote, code, list, image
}
let cases: [(String, String, Int)] = [
    ("figure_image_control", "<figure><img src='chart.jpg' alt='Chart'/></figure>", 1),
    ("standalone_with_alt_control", "<img src='chart.jpg' alt='Chart'/>", 1),
    ("image_inside_paragraph", "<p><img src='chart.jpg' alt='Chart'/></p>", 1),
    ("standalone_empty_alt", "<img src='chart.jpg' alt=''/>", 1),
    ("standalone_missing_alt", "<img src='chart.jpg'/>", 1),
    ("standalone_single_character_alt", "<img src='chart.jpg' alt='图'/>", 1),
    ("svg_wrapped_image", "<svg xmlns='http://www.w3.org/2000/svg'><image href='chart.jpg'/></svg>", 1),
    ("table_wrapped_image", "<table><tbody><tr><td><img src='chart.jpg' alt='Chart'/></td></tr></tbody></table>", 1),
    ("figure_two_images", "<figure><img src='table.jpg' alt='Table'/><img src='chart.jpg' alt='Chart'/></figure>", 2),
    ("text_div_with_inline_image", "<div>Example chart explanation <img src='chart.jpg' alt='Chart'/></div>", 1),
    ("screenshot_pattern", "<p>Table 1-1. AVERAGE ANNUAL RETURN</p><p><img src='table.jpg' alt='Table'/></p><p><img src='chart.jpg' alt='Chart'/></p><p>FIGURE 1-1</p>", 2),
    ("html_table", "<p>Table 1-1. AVERAGE ANNUAL RETURN</p><table><tr><td>S&amp;P 500</td><td>19.2%</td></tr></table>", 0)
]
var rows: [[String: Any]] = []
for (name, body, expected) in cases {
    let html = "<html><body><p>Before the illustration.</p>" + body + "<p>After the illustration.</p></body></html>"
    let blocks = HtmlParser.parse(html)
    let images = blocks.filter { $0.type == .image }
    rows.append([
        "case": name,
        "sourceImageCount": expected,
        "parsedImageCount": images.count,
        "imageHrefs": images.compactMap(\.imageHref),
        "text": blocks.filter { $0.type != .image }.map(\.text)
    ])
}
let output = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
print(String(data: output, encoding: .utf8)!)
