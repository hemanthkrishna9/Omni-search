import Foundation
import Testing
@testable import DigUpKit

#if !canImport(ImageIO)
/// RAW pictures off macOS are their embedded JPEG preview (Platform/Portable/RAW+Portable.swift). The files here are
/// built in the test: a TIFF (or Fujifilm's header) around Pictures/pattern-o6.jpg, a 400×240 pattern (red, green above
/// blue, yellow) whose own EXIF says orientation 6 and 2024:05:17 10:30:00. Each must hand the model the preview turned
/// as the RAW says, and a damaged file must fail with a note.
@Suite struct RAWTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let jpeg = [UInt8]((try? Data(contentsOf: ImageTests.pictures.appendingPathComponent("pattern-o6.jpg"))) ?? Data())

    /// One IFD entry: tag, type (3 SHORT, 4 LONG, 7 UNDEFINED), count, and the value (or offset).
    typealias Entry = (tag: Int, type: Int, count: Int, value: Int)

    static func put(_ value: Int, _ width: Int, little: Bool) -> [UInt8] {
        let bytes = (0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) }
        return little ? bytes : bytes.reversed()
    }

    /// The bytes of an IFD at the offset it will be written to: its entries (sorted), then the next IFD's offset.
    static func ifd(_ entries: [Entry], next: Int = 0, little: Bool) -> [UInt8] {
        var out = put(entries.count, 2, little: little)
        for e in entries.sorted(by: { $0.tag < $1.tag }) {
            out += put(e.tag, 2, little: little) + put(e.type, 2, little: little) + put(e.count, 4, little: little)
            out += put(e.value, e.type == 3 && e.count == 1 ? 2 : 4, little: little)
            if e.type == 3 && e.count == 1 { out += [0, 0] }
        }
        return out + put(next, 4, little: little)
    }

    /// A TIFF with `magic` (II/MM, then the version) and its first IFD at 8, then `after` (more IFDs, the JPEG).
    static func tiff(little: Bool, magic: [UInt8]? = nil, entries: [Entry], next: Int = 0, after: [UInt8]) -> [UInt8] {
        let header = magic ?? (little ? [0x49, 0x49, 0x2A, 0x00] : [0x4D, 0x4D, 0x00, 0x2A])
        return header + put(8, 4, little: little) + ifd(entries, next: next, little: little) + after
    }

    /// Where bytes after IFD0's `count` entries start in the file.
    static func end(ofIFD0 count: Int) -> Int { 8 + 2 + 12 * count + 4 }

    func write(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func shown(_ url: URL) throws -> (width: Int, height: Int, quadrants: [String], taken: String?) {
        let prepared = try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 256, to: folder, png: true)
        let picture = try ImageTests.decode(prepared.path)
        return (picture.width, picture.height, picture.quadrants, prepared.taken)
    }

    /// Canon's and Adobe's way: JPEGInterchangeFormat and its length in IFD0, orientation turning it upside down.
    @Test(arguments: ["shot.cr2", "shot.dng", "ÿ-ক-ب.arw"])
    func previewInIFD0(_ name: String) throws {
        #expect(Self.jpeg.count > 1000)
        let start = Self.end(ofIFD0: 3)
        let raw = Self.tiff(little: true, entries: [(0x0112, 3, 1, 3), (0x0201, 4, 1, start), (0x0202, 4, 1, Self.jpeg.count)],
                            after: Self.jpeg)
        let picture = try shown(write(raw, name))
        #expect(picture.width == 400 && picture.height == 240)
        #expect(picture.quadrants == ["Y", "B", "G", "R"])
        #expect(picture.taken == "2024:05:17 10:30:00")   // from the preview's own Exif: the RAW has none here
    }

    /// Without an orientation in the RAW, the preview's own is used; with one, only that.
    @Test func orientationFromTheRAWWins() throws {
        let start = Self.end(ofIFD0: 2)
        let plain = Self.tiff(little: true, entries: [(0x0201, 4, 1, start), (0x0202, 4, 1, Self.jpeg.count)], after: Self.jpeg)
        var picture = try shown(write(plain, "own.dng"))
        #expect(picture.width == 240 && picture.height == 400 && picture.quadrants == ["B", "R", "Y", "G"])
        let start3 = Self.end(ofIFD0: 3)
        let upright = Self.tiff(little: true, entries: [(0x0112, 3, 1, 1), (0x0201, 4, 1, start3), (0x0202, 4, 1, Self.jpeg.count)],
                            after: Self.jpeg)
        picture = try shown(write(upright, "upright.dng"))
        #expect(picture.width == 400 && picture.height == 240 && picture.quadrants == ["R", "G", "B", "Y"])
    }

    /// Big-endian (some Nikon files): a SubIFD holds the preview as a JPEG strip, beside a larger lossless-JPEG strip
    /// (raw sensor data, not a picture stb reads) in another SubIFD, and a thumbnail that ends too soon to decode in
    /// IFD0. The preview is the largest one that decodes. IFD0's orientation (6) is the one used.
    @Test func largestDecodablePreviewInASubIFD() throws {
        let thumb = Array(Self.jpeg.prefix(300))
        let lossless: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x10, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00]
            + [UInt8](repeating: 0x55, count: Self.jpeg.count * 2)
        func strip(_ at: Int, _ length: Int) -> [Entry] { [(0x0103, 3, 1, 7), (0x0111, 4, 1, at), (0x0117, 4, 1, length)] }
        func ifd0(_ thumbAt: Int, _ pointers: Int) -> [UInt8] {
            Self.ifd([(0x0112, 3, 1, 6), (0x0201, 4, 1, thumbAt), (0x0202, 4, 1, thumb.count), (0x014A, 4, 2, pointers)],
                     little: false)
        }
        let first = 8 + ifd0(0, 0).count                      // SubIFD A, then B, then the two offsets, then the data
        let second = first + Self.ifd(strip(0, 0), little: false).count
        let pointers = second + Self.ifd(strip(0, 0), little: false).count
        let data = pointers + 8
        let raw = [0x4D, 0x4D, 0x00, 0x2A] + Self.put(8, 4, little: false)
            + ifd0(data + lossless.count + Self.jpeg.count, pointers)
            + Self.ifd(strip(data, lossless.count), little: false)
            + Self.ifd(strip(data + lossless.count, Self.jpeg.count), little: false)
            + Self.put(first, 4, little: false) + Self.put(second, 4, little: false)
            + lossless + Self.jpeg + thumb
        let picture = try shown(write(raw, "sub.nef"))
        #expect(picture.width == 240 && picture.height == 400)
        #expect(picture.quadrants == ["B", "R", "Y", "G"])
    }

    /// Panasonic: tag 0x002E in IFD0 holds the JPEG as an UNDEFINED blob; the header's version is 0x55.
    @Test func panasonicJpgFromRaw() throws {
        let start = Self.end(ofIFD0: 2)
        let raw = Self.tiff(little: true, magic: [0x49, 0x49, 0x55, 0x00],
                            entries: [(0x0112, 3, 1, 1), (0x002E, 7, Self.jpeg.count, start)], after: Self.jpeg)
        let picture = try shown(write(raw, "shot.rw2"))
        #expect(picture.width == 400 && picture.quadrants == ["R", "G", "B", "Y"])
    }

    /// Olympus: "IIRO", and the preview in IFD1, the next IFD of the chain.
    @Test func olympusPreviewInTheChain() throws {
        let ifd0Size = Self.end(ofIFD0: 1)
        let next = ifd0Size
        let start = next + 2 + 12 * 2 + 4
        let first = Self.ifd([(0x0112, 3, 1, 6)], next: next, little: true)
        let second = Self.ifd([(0x0201, 4, 1, start), (0x0202, 4, 1, Self.jpeg.count)], little: true)
        let raw = [0x49, 0x49, 0x52, 0x4F] + Self.put(8, 4, little: true) + first + second + Self.jpeg
        let picture = try shown(write(raw, "shot.orf"))
        #expect(picture.width == 240 && picture.height == 400 && picture.quadrants == ["B", "R", "Y", "G"])
    }


    /// A JPEG whose header passes the check (baseline/progressive SOF) but stb can't decode: the frame says 12-bit
    /// samples. Padded to `length`.
    static func corruptJPEG(length: Int) -> [UInt8] {
        var bad = jpeg
        var i = 2   // walk the segments to the frame header
        while i + 4 <= bad.count, bad[i] == 0xFF, !(0xC0...0xC2).contains(bad[i + 1]) {
            i += 2 + (Int(bad[i + 2]) << 8 | Int(bad[i + 3]))
        }
        bad[i + 4] = 12
        return bad + [UInt8](repeating: 0, count: max(0, length - bad.count))
    }

    /// The largest candidate fails to decode: the next one down is used.
    @Test func fallsBackWhenTheLargestDoesNotDecode() throws {
        let bad = Self.corruptJPEG(length: Self.jpeg.count * 2)
        let start = Self.end(ofIFD0: 4) + 0
        // IFD0: thumbnail-style pointer to the good one, and a SubIFD-less strip entry for the corrupt (larger) one.
        let raw = Self.tiff(little: true, entries: [(0x0112, 3, 1, 1), (0x0201, 4, 1, start), (0x0202, 4, 1, Self.jpeg.count),
                                                   (0x002E, 7, bad.count, start + Self.jpeg.count)],
                            after: Self.jpeg + bad)
        let picture = try shown(write(raw, "fallback.rw2"))
        #expect(picture.width == 400 && picture.height == 240 && picture.quadrants == ["R", "G", "B", "Y"], "\(picture.quadrants)")
    }

    /// A preview too small to be a picture is the RAW's fault, not "small image"; the RAW's own size is the picture's.
    @Test func tinyPreviewInARAW() throws {
        let start = Self.end(ofIFD0: 2)
        let raw = Self.tiff(little: true, entries: [(0x0201, 4, 1, start), (0x0202, 4, 1, Self.jpeg.count)], after: Self.jpeg)
        let url = try write(raw, "tiny.dng")
        do {
            _ = try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 500, to: folder, png: true)
            Issue.record("read")
        } catch let error as ExtractError {
            #expect("\(error)".contains("unreadable") && "\(error)".contains("embedded preview is only 400×240"), "\(error)")
        }
    }

    /// The RAW's real size (a full-resolution IFD, NewSubfileType 0) is what's reported, not the preview's.
    @Test func reportsTheRAWsOwnSize() throws {
        // IFD0 holds the preview pointers and a SubIFD; the SubIFD is the 6000×4000 raw.
        let ifd0Count = 3
        let sub = Self.end(ofIFD0: ifd0Count)
        let subIFD = Self.ifd([(0x00FE, 4, 1, 0), (0x0100, 4, 1, 6000), (0x0101, 4, 1, 4000)], little: true)
        let start = sub + subIFD.count
        let raw = Self.tiff(little: true, entries: [(0x0201, 4, 1, start), (0x0202, 4, 1, Self.jpeg.count), (0x014A, 4, 1, sub)],
                            after: subIFD + Self.jpeg)
        let prepared = try ImageExtractor.prepare(write(raw, "size.dng"), maxPixel: 1024, minSide: 256, to: folder, png: true)
        #expect(prepared.width == 6000 && prepared.height == 4000)
    }

    /// Olympus new style: Exif IFD (from IFD0) → MakerNote "OLYMPUS\0II\3\0" → CameraSettings (0x2020) → preview
    /// start/length, all relative to the makernote's start. The only preview is there.
    @Test func olympusMakernotePreview() throws {
        let ifd0Size = Self.end(ofIFD0: 2)              // orientation, Exif pointer
        let exifAt = ifd0Size
        let exifSize = 2 + 12 + 4                       // one entry: MakerNote
        let noteAt = exifAt + exifSize
        // The makernote: 12-byte header, an IFD with 0x2020, then the settings IFD (offset relative to the note).
        let topSize = 2 + 12 + 4
        let settingsAt = 12 + topSize
        let settingsSize = 2 + 3 * 12 + 4
        let previewAt = settingsAt + settingsSize       // relative to the note
        let note = Array("OLYMPUS\0II".utf8) + [3, 0]
            + Self.ifd([(0x2020, 13, 1, settingsAt)], little: true)
            + Self.ifd([(0x0100, 4, 1, 1), (0x0101, 4, 1, previewAt), (0x0102, 4, 1, Self.jpeg.count)], little: true)
            + Self.jpeg
        let exif = Self.ifd([(0x927C, 7, note.count, noteAt)], little: true)
        let first = Self.ifd([(0x0112, 3, 1, 6), (0x8769, 4, 1, exifAt)], little: true)
        let raw = [0x49, 0x49, 0x52, 0x4F] + Self.put(8, 4, little: true) + first + exif + note
        let picture = try shown(write(raw, "note.orf"))
        #expect(picture.width == 240 && picture.height == 400 && picture.quadrants == ["B", "R", "Y", "G"])
    }

    /// Fuji: "FUJIFILMCCD-RAW", the JPEG's offset at 84 and length at 88, big-endian; the orientation is the JPEG's.
    @Test func fujiRAF() throws {
        var raw = [UInt8](repeating: 0, count: 160)
        raw.replaceSubrange(0..<15, with: Array("FUJIFILMCCD-RAW".utf8))
        raw.replaceSubrange(84..<88, with: Self.put(160, 4, little: false))
        raw.replaceSubrange(88..<92, with: Self.put(Self.jpeg.count, 4, little: false))
        let picture = try shown(write(raw + Self.jpeg + [UInt8](repeating: 0, count: 64), "shot.raf"))
        #expect(picture.width == 240 && picture.height == 400 && picture.quadrants == ["B", "R", "Y", "G"])
        #expect(picture.taken == "2024:05:17 10:30:00")
    }

    /// Whatever is wrong with the file, it fails with an error and never traps.
    @Test func damagedFilesFailCleanly() throws {
        let start = Self.end(ofIFD0: 2)
        let good = Self.tiff(little: true, entries: [(0x0201, 4, 1, start), (0x0202, 4, 1, Self.jpeg.count)], after: Self.jpeg)
        var damaged: [String: [UInt8]] = [:]
        damaged["cut.dng"] = Array(good.prefix(good.count - 500))            // the JPEG runs past the end
        damaged["header.cr2"] = Array(good.prefix(6))                         // not even a first IFD offset
        damaged["empty.nef"] = []
        damaged["noise.arw"] = (0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) }
        damaged["far.dng"] = Self.tiff(little: true, entries: [(0x0201, 4, 1, 1 << 30), (0x0202, 4, 1, 5000)], after: [])
        damaged["huge.dng"] = Self.tiff(little: true, entries: [(0x0201, 4, 1, start), (0x0202, 4, 1, 0xFFFF_FFFF)], after: Self.jpeg)
        damaged["negative.dng"] = Self.tiff(little: true, entries: [(0x0201, 4, 1, 0xFFFF_FFFF), (0x0202, 4, 1, 0xFFFF_FFFF)], after: [])
        damaged["loop.dng"] = Self.tiff(little: true, entries: [(0x0112, 3, 1, 1)], next: 8, after: [])   // IFD0 is its own next
        damaged["subloop.dng"] = Self.tiff(little: false, entries: [(0x014A, 4, 1, 8)], after: [])
        damaged["count.dng"] = [0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, 0xFF, 0xFF, 0x12, 0x01]   // 65535 entries, none there
        damaged["nopreview.dng"] = Self.tiff(little: true, entries: [(0x0112, 3, 1, 1)], after: [])
        damaged["notajpeg.dng"] = Self.tiff(little: true, entries: [(0x0201, 4, 1, start), (0x0202, 4, 1, 100)],
                                            after: [UInt8](repeating: 7, count: 100))
        damaged["short.raf"] = Array("FUJIFILMCCD-RAW".utf8) + [0, 0, 0]
        var wrongPlace = [UInt8](repeating: 0, count: 100)
        wrongPlace.replaceSubrange(0..<15, with: Array("FUJIFILMCCD-RAW".utf8))
        wrongPlace.replaceSubrange(84..<88, with: Self.put(90, 4, little: false))
        wrongPlace.replaceSubrange(88..<92, with: Self.put(500, 4, little: false))
        damaged["place.raf"] = wrongPlace
        for (name, bytes) in damaged {
            let url = try write(bytes, name)
            do {
                _ = try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 256, to: folder, png: true)
                Issue.record("\(name) was read")
            } catch let error as ExtractError {
                #expect("\(error)".hasPrefix("unreadable"), "\(name): \(error)")
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
    }

    /// A RAW is an image for the indexer, not something to skip.
    @Test func rawFilesAreImages() {
        for name in ["a.cr2", "a.nef", "a.arw", "a.dng", "a.raf", "a.orf", "a.rw2"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(Rules.imageExtensions.contains(url.pathExtension))
        }
    }
}
#endif
