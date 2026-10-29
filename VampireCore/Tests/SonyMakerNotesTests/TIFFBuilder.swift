import Foundation

/// Builds synthetic ARW-shaped TIFF buffers for parser tests: real fixture
/// files exercise real layouts; this builder exercises structural variation
/// (endianness, inline vs. pointed values, truncation) deterministically.
struct TIFFBuilder {
    enum Endianness { case little, big }

    struct EntrySpec {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        /// Inline payload (≤4 bytes, already padded) or out-of-line payload
        /// that the builder will place and point to.
        let payload: Data
        let forceOutOfLine: Bool

        init(tag: UInt16, type: UInt16, count: UInt32, payload: Data, forceOutOfLine: Bool = false) {
            self.tag = tag
            self.type = type
            self.count = count
            self.payload = payload
            self.forceOutOfLine = forceOutOfLine
        }
    }

    let endianness: Endianness

    func u16(_ v: UInt16) -> Data {
        var x = endianness == .little ? v.littleEndian : v.bigEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    func u32(_ v: UInt32) -> Data {
        var x = endianness == .little ? v.littleEndian : v.bigEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    func shortValues(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { $0.append(u16($1)) }
    }

    func longValues(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { $0.append(u32($1)) }
    }

    func ascii(_ string: String) -> Data {
        Data(string.utf8) + Data([0])
    }

    /// Serializes an IFD at `offset`, appending out-of-line values after the
    /// entry table. Returns the complete IFD block (entries + values).
    /// Out-of-line value pointers are absolute (TIFF-header-relative), which
    /// is also Sony's maker note convention.
    func ifdBlock(at offset: Int, entries: [EntrySpec], nextIFD: UInt32 = 0) -> Data {
        var table = u16(UInt16(entries.count))
        let tableSize = 2 + entries.count * 12 + 4
        var overflow = Data()

        for entry in entries {
            table.append(u16(entry.tag))
            table.append(u16(entry.type))
            table.append(u32(entry.count))
            if entry.payload.count <= 4 && !entry.forceOutOfLine {
                var inline = entry.payload
                inline.append(Data(count: 4 - inline.count))
                table.append(inline)
            } else {
                let pointer = UInt32(offset + tableSize + overflow.count)
                table.append(u32(pointer))
                overflow.append(entry.payload)
            }
        }
        table.append(u32(nextIFD))
        return table + overflow
    }

    /// Assembles a minimal ARW head: TIFF header, IFD0 (Make/Model/Orientation
    /// + ExifIFD pointer), Exif IFD (DateTimeOriginal/SubSec + MakerNote), and
    /// a Sony maker note IFD carrying the given tags.
    static func sonyARWHead(
        endianness: Endianness = .little,
        focusLocation: [UInt32]? = [9504, 6336, 4752, 3168],
        focusLocationType: UInt16 = 3, // SHORT, as written by A7RV-era bodies
        /// Tag 0x2037 payload, written as undef[2n] like the camera does.
        focusFrameSize: [UInt16]? = nil,
        dateTimeOriginal: String = "2026:06:01 10:15:30",
        subSecTimeOriginal: String? = "57",
        /// nil = signatureless bare-IFD maker note (A7RV-generation layout).
        makerNoteSignature: String? = "SONY DSC \0\0\0",
        extraMakerNoteTags: [EntrySpec] = []
    ) -> Data {
        let b = TIFFBuilder(endianness: endianness)

        var header = endianness == .little ? Data([0x49, 0x49]) : Data([0x4D, 0x4D])
        header.append(b.u16(42))
        header.append(b.u32(8)) // IFD0 directly after header

        // Layout is computed in two passes because pointers are absolute:
        // sizes first, then re-serialize with real offsets.
        func build(ifd0Offset: Int) -> Data {
            // Pass 1: maker note content at a placeholder offset to learn sizes.
            var makerEntries: [EntrySpec] = extraMakerNoteTags
            if let focus = focusLocation {
                let payload: Data
                if focusLocationType == 3 {
                    payload = b.shortValues(focus.map { UInt16($0) })
                } else {
                    payload = b.longValues(focus)
                }
                makerEntries.insert(
                    EntrySpec(tag: 0x2027, type: focusLocationType, count: 4, payload: payload),
                    at: 0
                )
            }
            if let focusFrameSize {
                let payload = b.shortValues(focusFrameSize)
                makerEntries.append(
                    EntrySpec(tag: 0x2037, type: 7, count: UInt32(payload.count), payload: payload)
                )
            }

            var exifEntries: [EntrySpec] = [
                EntrySpec(tag: 0x9003, type: 2, count: UInt32(dateTimeOriginal.utf8.count + 1),
                          payload: b.ascii(dateTimeOriginal)),
            ]
            if let subSec = subSecTimeOriginal {
                exifEntries.append(EntrySpec(tag: 0x9291, type: 2, count: UInt32(subSec.utf8.count + 1),
                                             payload: b.ascii(subSec)))
            }

            let make = b.ascii("SONY")
            let model = b.ascii("ILCE-7RM5")
            let ifd0Entries: [EntrySpec] = [
                EntrySpec(tag: 0x010F, type: 2, count: UInt32(make.count), payload: make),
                EntrySpec(tag: 0x0110, type: 2, count: UInt32(model.count), payload: model),
                EntrySpec(tag: 0x0112, type: 3, count: 1, payload: b.shortValues([1])),
            ]

            // Iterate offsets to a fixed point (sizes don't change between passes).
            var exifIFDOffset = 0
            var makerNoteOffset = 0
            var result = Data()
            for _ in 0 ..< 3 {
                var ifd0 = ifd0Entries
                ifd0.append(EntrySpec(tag: 0x8769, type: 4, count: 1,
                                      payload: b.longValues([UInt32(exifIFDOffset)])))
                let ifd0Block = b.ifdBlock(at: ifd0Offset, entries: ifd0)

                exifIFDOffset = ifd0Offset + ifd0Block.count
                var makerNote = Data()
                if let makerNoteSignature {
                    makerNote = Data(makerNoteSignature.utf8)
                    precondition(makerNote.count == 12, "signature must be 12 bytes")
                }
                makerNote.append(b.ifdBlock(at: makerNoteOffset + makerNote.count, entries: makerEntries))

                var exif = exifEntries
                exif.append(EntrySpec(tag: 0x927C, type: 7, count: UInt32(makerNote.count),
                                      payload: makerNote, forceOutOfLine: true))
                let exifBlock = b.ifdBlock(at: exifIFDOffset, entries: exif)

                // The maker note payload is the last out-of-line value of the
                // exif block; recover its offset for the next iteration.
                makerNoteOffset = exifIFDOffset + exifBlock.count - makerNote.count
                result = ifd0Block + exifBlock
            }
            return result
        }

        return header + build(ifd0Offset: 8)
    }

    /// Synthetic Fuji EXIF JPEG: SOI + APP1(Exif + TIFF with Fuji maker note).
    /// Fuji maker note: "FUJIFILM" + LE u32 IFD offset, all offsets relative
    /// to the maker note start (matches fixtures/DSCF2763.jpg).
    static func fujiJPEGHead(
        pixelWidth: UInt32 = 7728,
        pixelHeight: UInt32 = 5152,
        focusPixel: [UInt16]? = [6052, 2063],
        faceCorners: [UInt16] = [5204, 1366, 7207, 2961]
    ) -> Data {
        let b = TIFFBuilder(endianness: .little)

        // Maker note, self-relative: header is 12 bytes, IFD follows.
        var makerEntries: [EntrySpec] = []
        if let focusPixel {
            makerEntries.append(EntrySpec(
                tag: 0x1023, type: 3, count: 2,
                payload: b.shortValues(focusPixel) // int32u carrying 2×u16
            ))
        }
        makerEntries.append(EntrySpec(
            tag: 0x4100, type: 3, count: 1,
            payload: b.shortValues([UInt16(faceCorners.count / 4)])
        ))
        if !faceCorners.isEmpty {
            makerEntries.append(EntrySpec(
                tag: 0x4103, type: 3, count: UInt32(faceCorners.count),
                payload: b.shortValues(faceCorners)
            ))
        }
        var makerNote = Data("FUJIFILM".utf8)
        makerNote.append(b.u32(12))
        makerNote.append(b.ifdBlock(at: 12, entries: makerEntries))

        // TIFF: IFD0 (make/model + Exif ptr) + Exif IFD (dims + maker note).
        func buildTIFF() -> Data {
            var header = Data([0x49, 0x49])
            header.append(b.u16(42))
            header.append(b.u32(8))

            let make = b.ascii("FUJIFILM")
            let model = b.ascii("X-T5")
            var exifIFDOffset = 0
            var result = Data()
            for _ in 0 ..< 3 {
                let ifd0 = b.ifdBlock(at: 8, entries: [
                    EntrySpec(tag: 0x010F, type: 2, count: UInt32(make.count), payload: make),
                    EntrySpec(tag: 0x0110, type: 2, count: UInt32(model.count), payload: model),
                    EntrySpec(tag: 0x8769, type: 4, count: 1, payload: b.longValues([UInt32(exifIFDOffset)])),
                ])
                exifIFDOffset = 8 + ifd0.count
                let exif = b.ifdBlock(at: exifIFDOffset, entries: [
                    EntrySpec(tag: 0x9003, type: 2, count: 20, payload: b.ascii("2025:04:26 10:59:00")),
                    EntrySpec(tag: 0x927C, type: 7, count: UInt32(makerNote.count),
                              payload: makerNote, forceOutOfLine: true),
                    EntrySpec(tag: 0xA002, type: 4, count: 1, payload: b.longValues([pixelWidth])),
                    EntrySpec(tag: 0xA003, type: 4, count: 1, payload: b.longValues([pixelHeight])),
                ])
                result = header + ifd0 + exif
            }
            return result
        }

        let tiff = buildTIFF()
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1])
        let payload = Data("Exif\0\0".utf8) + tiff
        var length = UInt16(payload.count + 2).bigEndian
        withUnsafeBytes(of: &length) { jpeg.append(contentsOf: $0) }
        jpeg.append(payload)
        jpeg.append(contentsOf: [0xFF, 0xD9])
        return jpeg
    }

    /// Wraps a JPEG in a minimal RAF container (offset field at byte 84, BE).
    static func rafContainer(wrapping jpeg: Data, jpegOffset: Int = 148) -> Data {
        var raf = Data("FUJIFILMCCD-RAW ".utf8)
        raf.append(Data(count: 84 - raf.count))
        var offset = UInt32(jpegOffset).bigEndian
        withUnsafeBytes(of: &offset) { raf.append(contentsOf: $0) }
        var length = UInt32(jpeg.count).bigEndian
        withUnsafeBytes(of: &length) { raf.append(contentsOf: $0) }
        raf.append(Data(count: jpegOffset - raf.count))
        raf.append(jpeg)
        return raf
    }
}
