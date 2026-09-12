#!/usr/bin/env swift
// Compare two device exports by source position and decoded pixels; never emit book text.
import Foundation
import CoreGraphics
import ImageIO

struct Book: Decodable {
    struct Page: Decodable {
        struct Position: Decodable, Equatable {
            let start: Int, end: Int, minimum: Int, maximum: Int
            let layoutID: String
        }
        struct Resource: Decodable { let imageHash: String }
        let ordinal: Int, position: Position, resource: Resource
    }
    let id: String, generation: String, pages: [Page]
}

func pixels(_ url: URL) throws -> (Int, Int, Data) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height,
              bitsPerComponent: 8, bytesPerRow: image.width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = context.data else { throw NSError(domain: "ImageDecode", code: 1) }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, Data(bytes: bytes, count: image.width * image.height * 4))
}

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift compare-kindle-offline-images.swift old.book new.book")
}
let urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
let books = try urls.map { try JSONDecoder().decode(Book.self, from: Data(contentsOf: $0)) }
let directories = zip(urls, books).map { url, book in
    url.deletingLastPathComponent().appendingPathComponent(book.id)
        .appendingPathComponent(book.generation).appendingPathComponent(book.id)
}
var positionMismatches: [Int] = [], pixelMismatches: [Int] = []
var byteIdentical = 0, pixelIdentical = 0, equivalent = 0, maximumChannelDelta = 0
var maximumChangedPixelFraction = 0.0
for (old, new) in zip(books[0].pages, books[1].pages) {
    if old.ordinal != new.ordinal || old.position != new.position { positionMismatches.append(new.ordinal) }
    if old.resource.imageHash == new.resource.imageHash {
        byteIdentical += 1
        pixelIdentical += 1
        equivalent += 1
    } else {
        let a = try pixels(directories[0].appendingPathComponent(old.resource.imageHash + ".image"))
        let b = try pixels(directories[1].appendingPathComponent(new.resource.imageHash + ".image"))
        guard a.0 == b.0, a.1 == b.1 else { pixelMismatches.append(new.ordinal); continue }
        if a.2 == b.2 { pixelIdentical += 1; equivalent += 1; continue }
        var delta = 0, changed = 0
        a.2.withUnsafeBytes { (left: UnsafeRawBufferPointer) in
            b.2.withUnsafeBytes { (right: UnsafeRawBufferPointer) in
                for offset in stride(from: 0, to: left.count, by: 4) {
                    var pixelDelta = 0
                    for channel in 0..<4 {
                        pixelDelta = max(pixelDelta, abs(Int(left[offset + channel]) - Int(right[offset + channel])))
                    }
                    if pixelDelta > 0 { changed += 1 }
                    delta = max(delta, pixelDelta)
                }
            }
        }
        let fraction = Double(changed) / Double(a.0 * a.1)
        maximumChannelDelta = max(maximumChannelDelta, delta)
        maximumChangedPixelFraction = max(maximumChangedPixelFraction, fraction)
        // Separate exact equality from tiny rasterization differences: at most
        // one 8-bit level, affecting no more than 0.1% of the page's pixels.
        if delta <= 1, fraction <= 0.001 { equivalent += 1 }
        else { pixelMismatches.append(new.ordinal) }
    }
}
let result: [String: Any] = ["oldPages": books[0].pages.count, "newPages": books[1].pages.count,
    "byteIdentical": byteIdentical, "pixelIdentical": pixelIdentical,
    "visuallyEquivalentPages": equivalent, "maximumChannelDelta": maximumChannelDelta,
    "maximumChangedPixelFraction": maximumChangedPixelFraction,
    "allowedChannelDelta": 1, "allowedChangedPixelFraction": 0.001,
    "sourcePositionMismatches": positionMismatches, "pixelMismatches": pixelMismatches,
    "allPagesEquivalent": books[0].pages.count == books[1].pages.count && positionMismatches.isEmpty && pixelMismatches.isEmpty]
let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
print(String(decoding: output, as: UTF8.self))
if result["allPagesEquivalent"] as? Bool != true { exit(1) }
