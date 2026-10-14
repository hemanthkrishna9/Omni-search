// RAW pictures without ImageIO (Linux, Windows): every camera RAW embeds a JPEG preview, so that is what's read, the
// largest one in the file, through the same stb path as any JPEG. Canon CR2, Nikon NEF, Sony ARW, Adobe DNG, Olympus ORF
// and Panasonic RW2 are TIFF-like (IFD0, its chain, SubIFDs and the Exif IFD hold the previews); Fujifilm RAF has a
// fixed header that points at its JPEG. Nothing here trusts the file: every read is bounds-checked and the IFD walk is
// capped, so a truncated or hostile file fails with a note instead of trapping or looping. Olympus ORF keeps its
// full-size preview in the makernote (see `Walk.olympusPreview`). Phone DNGs often have no JPEG preview at all (only
// the raw data, or a tiny thumbnail); they fail with `noPreview`.
#if !canImport(ImageIO)
import Foundation

enum RAW {
    static let extensions: Set<String> = ["cr2", "nef", "arw", "dng", "raf", "orf", "rw2"]

    /// The embedded picture to decode, and what the file says about how it's held and when it was taken.
    struct Preview {
        var jpeg: Data
        var orientation: Int
        var taken: String?
        /// The RAW's own size (the Exif pixel dimensions, or the full-resolution IFD's), when the file says.
        var width: Int?
        var height: Int?
    }

    /// Where a candidate JPEG sits in the file.
    private struct Candidate {
        var offset: Int
        var length: Int
    }

    static let noPreview = "this RAW picture has no readable JPEG preview"
    private static let maxPreview = 128 << 20
    private static let maxIFDs = 64
    private static let maxEntries = 1000
    private static let maxDecodes = 8

    /// The largest embedded JPEG that `decode` accepts (stb reads baseline and progressive JPEG, not the lossless JPEG
    /// some DNGs keep their sensor data in, nor 12-bit ones). Candidates are tried largest first, so a preview whose
    /// header looks right but whose body is damaged falls back to the next. Throws with a note when there is none.
    static func preview<T>(of url: URL, decode: (Data) -> T?) throws -> (preview: Preview, decoded: T) {
        guard let reader = try? FileReader(url), reader.size < UInt64(Int.max) else {
            throw ExtractError.unreadable("can't read the file")
        }
        let file = Source(size: Int(reader.size)) { at, count in
            var out = [UInt8](repeating: 0, count: count)
            let got = out.withUnsafeMutableBytes { reader.read(at: UInt64(at), into: $0.baseAddress!, count: count) }
            return got == count ? out : nil
        }
        guard let head = file.bytes(0, min(file.size, 16)), head.count >= 8 else { throw ExtractError.unreadable(noPreview) }
        var found: [Candidate] = []
        var orientation: Int?
        var taken: String?
        var dimensions: (width: Int, height: Int)?
        if head.starts(with: Array("FUJIFILMCCD-RAW".utf8)) {
            if let offset = file.u32(84, little: false), let length = file.u32(88, little: false) {
                found.append(Candidate(offset: offset, length: length))
            }
        } else if let little = byteOrder(head) {
            var walk = Walk(file: file, base: 0, little: little, collects: true)
            walk.run()
            (found, orientation, taken, dimensions) = (walk.candidates, walk.orientation, walk.taken, walk.dimensions)
        } else {
            throw ExtractError.unreadable(noPreview)
        }
        // Largest first; the first that is a JPEG stb can decode wins (a few tries at most).
        let usable = found.filter { $0.length >= 4 && $0.length <= maxPreview && $0.offset >= 0
            && $0.offset <= file.size - $0.length }
        var tries = 0
        for candidate in usable.sorted(by: { $0.length > $1.length }) {
            guard let start = file.bytes(candidate.offset, min(candidate.length, 1 << 18)), start.starts(with: [0xFF, 0xD8]),
                  isDecodableJPEG(start), let bytes = file.bytes(candidate.offset, candidate.length) else { continue }
            tries += 1
            if tries > maxDecodes { break }
            let data = Data(bytes)
            guard let decoded = decode(data) else { continue }
            var facts = (orientation: orientation, taken: taken)
            if facts.orientation == nil || facts.taken == nil {
                let inside = jpegFacts(bytes)
                facts = (facts.orientation ?? inside.orientation, facts.taken ?? inside.taken)
            }
            return (Preview(jpeg: data, orientation: facts.orientation ?? 1, taken: facts.taken,
                            width: dimensions?.width, height: dimensions?.height), decoded)
        }
        throw ExtractError.unreadable(noPreview)
    }

    /// Little-endian for "II", big for "MM", nil for anything else.
    private static func byteOrder(_ head: [UInt8]) -> Bool? {
        if head[0] == 0x49, head[1] == 0x49 { return true }
        if head[0] == 0x4D, head[1] == 0x4D { return false }
        return nil
    }

    /// Whether the JPEG's frame header says baseline or progressive Huffman (SOF0 to SOF2); a lossless one (SOF3) is a
    /// DNG's raw data. A header beyond the bytes given is left for stb to judge.
    private static func isDecodableJPEG(_ start: [UInt8]) -> Bool {
        var i = 2
        while i + 4 <= start.count, start[i] == 0xFF {
            let marker = start[i + 1]
            if marker == 0xFF { i += 1; continue }
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { return marker <= 0xC2 }
            if marker == 0xDA || marker == 0xD9 { return true }
            i += 2 + (Int(start[i + 2]) << 8 | Int(start[i + 3]))
        }
        return true
    }

    /// The orientation and DateTimeOriginal in a JPEG's own APP1 Exif segment (RAF keeps them only there).
    private static func jpegFacts(_ jpeg: [UInt8]) -> (orientation: Int?, taken: String?) {
        let limit = min(jpeg.count, 1 << 20)
        var i = 2
        while i + 4 <= limit, jpeg[i] == 0xFF {
            let marker = jpeg[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
            if marker == 0xE1, length >= 16, i + 10 + 8 <= jpeg.count, jpeg[(i + 4)..<(i + 10)].elementsEqual("Exif\0\0".utf8) {
                let end = min(jpeg.count, i + 2 + length)
                let tiff = Array(jpeg[(i + 10)..<end])
                guard let little = byteOrder(tiff) else { return (nil, nil) }
                var walk = Walk(file: Source(bytes: tiff), base: 0, little: little, collects: false)
                walk.run()
                return (walk.orientation, walk.taken)
            }
            i += 2 + length
        }
        return (nil, nil)
    }

    /// A TIFF structure's IFDs, visited breadth first from IFD0, collecting what the previews need.
    private struct Walk {
        let file: Source
        let base: Int   // where the TIFF header starts; every offset in it is relative to this
        let little: Bool
        let collects: Bool
        var candidates: [Candidate] = []
        var orientation: Int?
        var taken: String?
        var dimensions: (width: Int, height: Int)?

        init(file: Source, base: Int, little: Bool, collects: Bool) {
            (self.file, self.base, self.little, self.collects) = (file, base, little, collects)
        }

        /// One IFD's entries, by tag.
        private struct Table {
            var tags: [Int: (type: Int, count: Int, field: Int)] = [:]
            var bytes: [UInt8] = []
            var count = 0   // as the file says; `tags` holds at most `maxEntries`
        }

        mutating func run() {
            guard let first = file.u32(base + 4, little: little) else { return }
            var queue: [(at: Int, isIFD0: Bool, isExif: Bool)] = [(first, true, false)]
            var seen = Set<Int>()
            var walked = 0
            var index = 0
            while index < queue.count, walked < RAW.maxIFDs {
                let (at, isIFD0, isExif) = queue[index]
                index += 1
                guard at >= 8, seen.insert(at).inserted else { continue }
                walked += 1
                visit(at, isIFD0: isIFD0, isExif: isExif, queue: &queue)
            }
        }

        private func read(_ at: Int) -> Table? {
            guard let count = file.u16(base + at, little: little), count > 0 else { return nil }
            let n = min(count, RAW.maxEntries)
            guard let bytes = file.bytes(base + at + 2, n * 12) else { return nil }
            var table = Table(bytes: bytes, count: count)
            for e in 0..<n {
                let o = e * 12
                table.tags[Source.u16(bytes, o, little)] = (Source.u16(bytes, o + 2, little), Source.u32(bytes, o + 4, little), o + 8)
            }
            return table
        }

        /// The integers of a SHORT or LONG entry (inline, or at its offset), capped.
        private func values(_ table: Table, _ tag: Int, limit: Int = 4096) -> [Int] {
            guard let entry = table.tags[tag], entry.type == 3 || entry.type == 4, entry.count > 0 else { return [] }
            let size = entry.type == 3 ? 2 : 4, number = min(entry.count, limit)
            let place = entry.count * size <= 4 ? nil : Source.u32(table.bytes, entry.field, little)
            let raw: [UInt8]
            if let place {
                guard let read = file.bytes(base + place, number * size) else { return [] }
                raw = read
            } else {
                raw = Array(table.bytes[entry.field..<(entry.field + number * size)])
            }
            return (0..<number).map { size == 2 ? Source.u16(raw, $0 * 2, little) : Source.u32(raw, $0 * 4, little) }
        }

        /// One IFD: its entries, and the IFDs it leads to appended to `queue`.
        private mutating func visit(_ at: Int, isIFD0: Bool, isExif: Bool,
                                    queue: inout [(at: Int, isIFD0: Bool, isExif: Bool)]) {
            guard let table = read(at) else { return }
            let tags = table.tags
            func values(_ tag: Int, limit: Int = 4096) -> [Int] { self.values(table, tag, limit: limit) }
            if isIFD0, let value = values(0x0112).first { orientation = value }
            if isExif, tags[0x9003]?.type == 2, let entry = tags[0x9003], entry.count >= 19 {
                let place = Source.u32(table.bytes, entry.field, little)
                if let text = file.bytes(base + place, 19) { taken = String(decoding: text, as: UTF8.self) }
            }
            guard collects || isIFD0 || isExif else { return }
            if collects {
                // The RAW's own size: the Exif pixel dimensions, or the full-resolution IFD's (NewSubfileType 0, which
                // IFD0 of a file whose IFD0 is a thumbnail doesn't say).
                if isExif {
                    if let w = values(0xA002).first, let h = values(0xA003).first { noteSize(w, h) }
                } else if values(0x00FE).first == 0, let w = values(0x0100).first, let h = values(0x0101).first {
                    noteSize(w, h)
                }
                if let start = values(0x0201).first, let length = values(0x0202).first {
                    candidates.append(Candidate(offset: base + start, length: length))
                }
                // JPEG-compressed strips (a DNG's or NEF's preview): contiguous ones make one picture.
                if let compression = values(0x0103).first, compression == 6 || compression == 7 {
                    let starts = values(0x0111), lengths = values(0x0117)
                    if !starts.isEmpty, starts.count == lengths.count {
                        var end = starts[0] + lengths[0], total = lengths[0], contiguous = true
                        for k in 1..<starts.count {
                            if starts[k] != end { contiguous = false; break }
                            end += lengths[k]
                            total += lengths[k]
                        }
                        if contiguous, total > 0 { candidates.append(Candidate(offset: base + starts[0], length: total)) }
                    }
                }
                // Panasonic's JpgFromRaw: an UNDEFINED blob (count is its length) at the offset.
                if let blob = tags[0x002E], blob.type == 7, blob.count > 4 {
                    candidates.append(Candidate(offset: base + Source.u32(table.bytes, blob.field, little), length: blob.count))
                }
                for sub in values(0x014A, limit: 32) { queue.append((sub, false, false)) }
                if isExif, let note = tags[0x927C], note.type == 7, note.count >= 16 {
                    olympusPreview(at: base + Source.u32(table.bytes, note.field, little), size: note.count)
                }
            }
            if let exif = values(0x8769).first { queue.append((exif, false, true)) }
            if isIFD0 || collects,
               let next = file.u32(base + at + 2 + table.count * 12, little: little), table.count <= RAW.maxEntries, next != 0 {
                queue.append((next, false, false))
            }
        }

        private mutating func noteSize(_ width: Int, _ height: Int) {
            guard width > 0, height > 0, width <= 1 << 20, height <= 1 << 20 else { return }
            if let known = dimensions, known.width * known.height >= width * height { return }
            dimensions = (width, height)
        }

        /// Olympus keeps its full-size preview in the makernote (Exif tag 0x927C), not in the TIFF chain: after a header,
        /// an IFD whose tag 0x2020 (CameraSettings) leads to another with PreviewImageValid (0x0100), PreviewImageStart
        /// (0x0101) and PreviewImageLength (0x0102). The new style ("OLYMPUS\0II\x03\0", or "MM") has every offset
        /// relative to the makernote's start and its IFD 12 bytes in; the old style ("OLYMP\0", a 2-byte version) has
        /// them relative to the TIFF header, its IFD 8 bytes in. `at` is the makernote's place in the file.
        private mutating func olympusPreview(at: Int, size: Int) {
            guard at >= 0, let head = file.bytes(at, 12) else { return }
            let sub: Walk, first: Int
            if head.starts(with: Array("OLYMPUS\0".utf8)), let order = RAW.byteOrder(Array(head[8...])) {
                sub = Walk(file: file, base: at, little: order, collects: false)
                first = 12
            } else if head.starts(with: Array("OLYMP\0".utf8)) {
                sub = Walk(file: file, base: base, little: little, collects: false)
                first = at - base + 8
            } else {
                return
            }
            guard let top = sub.read(first), let entry = top.tags[0x2020], entry.type == 4 || entry.type == 13,
                  entry.count == 1 else { return }
            let settingsAt = Source.u32(top.bytes, entry.field, sub.little)
            guard settingsAt > 0, let settings = sub.read(settingsAt) else { return }
            if let valid = sub.values(settings, 0x0100).first, valid == 0 { return }
            if let start = sub.values(settings, 0x0101).first, let length = sub.values(settings, 0x0102).first {
                candidates.append(Candidate(offset: sub.base + start, length: length))
            }
        }
    }

    /// Bytes read where asked, bounds-checked: nil rather than short or past the end.
    private struct Source {
        let size: Int
        let fetch: (Int, Int) -> [UInt8]?

        init(size: Int, fetch: @escaping (Int, Int) -> [UInt8]?) { (self.size, self.fetch) = (size, fetch) }

        init(bytes: [UInt8]) {
            self.init(size: bytes.count) { at, count in bytes[at..<(at + count)].map { $0 } }
        }

        func bytes(_ at: Int, _ count: Int) -> [UInt8]? {
            guard at >= 0, count >= 0, at <= size, count <= size - at else { return nil }
            return count == 0 ? [] : fetch(at, count)
        }

        func u16(_ at: Int, little: Bool) -> Int? { bytes(at, 2).map { Self.u16($0, 0, little) } }
        func u32(_ at: Int, little: Bool) -> Int? { bytes(at, 4).map { Self.u32($0, 0, little) } }

        static func u16(_ b: [UInt8], _ at: Int, _ little: Bool) -> Int {
            little ? Int(b[at]) | Int(b[at + 1]) << 8 : Int(b[at]) << 8 | Int(b[at + 1])
        }

        static func u32(_ b: [UInt8], _ at: Int, _ little: Bool) -> Int {
            little ? Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24
                   : Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
        }
    }
}
#endif
