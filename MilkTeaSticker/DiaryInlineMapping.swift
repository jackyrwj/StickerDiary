import Foundation

/// Pure text logic behind the inline diary layout, kept free of UIKit so it
/// can be tested on its own.
///
/// The inline editor shows every paragraph as one text joined by blank lines.
/// After an edit, this splits the text back into paragraphs and works out
/// which existing paragraph each new one corresponds to. All offsets are
/// UTF-16, matching NSString and UITextView ranges.
enum DiaryInlineMapping {
    static let separator = "\n\n"

    struct Block: Equatable {
        var text: String
        var start: Int
        var length: Int
    }

    struct Alignment: Equatable {
        /// For each new paragraph, the index of the old paragraph it continues
        /// (`nil` means it is a brand-new paragraph).
        var assignment: [Int?]
        /// Old paragraphs that disappeared, mapped to the new paragraph that
        /// absorbed them (`-1` when there is none before them).
        var absorbedBy: [Int: Int]
    }

    /// Splits the combined text on blank lines. Always returns at least one block.
    static func blocks(in text: String) -> [Block] {
        let ns = text as NSString
        var result: [Block] = []
        var location = 0
        while true {
            let searchRange = NSRange(location: location, length: ns.length - location)
            let found = ns.range(of: separator, options: [], range: searchRange)
            if found.location == NSNotFound {
                result.append(Block(text: ns.substring(from: location), start: location, length: ns.length - location))
                return result
            }
            let range = NSRange(location: location, length: found.location - location)
            result.append(Block(text: ns.substring(with: range), start: location, length: range.length))
            location = found.location + found.length
        }
    }

    /// The block an insertion at `characterIndex` belongs to, and its offset
    /// inside that block (clamped to the block's bounds).
    static func locate(_ characterIndex: Int, in blocks: [Block]) -> (block: Int, offset: Int) {
        guard !blocks.isEmpty else { return (0, 0) }
        let index = blocks.firstIndex { characterIndex <= $0.start + $0.length } ?? blocks.count - 1
        let offset = min(max(characterIndex - blocks[index].start, 0), blocks[index].length)
        return (index, offset)
    }

    /// Matches old paragraphs to new ones. Paragraphs with identical text
    /// anchor the match; the ones between anchors are paired up in order.
    static func align(old: [String], new: [String]) -> Alignment {
        var assignment = [Int?](repeating: nil, count: new.count)
        var absorbedBy: [Int: Int] = [:]
        var previousOld = -1
        var previousNew = -1

        for (oldIndex, newIndex) in longestCommonSubsequence(old, new) + [(old.count, new.count)] {
            let gapOld = Array((previousOld + 1)..<oldIndex)
            let gapNew = Array((previousNew + 1)..<newIndex)
            for (offset, newPosition) in gapNew.enumerated() where offset < gapOld.count {
                assignment[newPosition] = gapOld[offset]
            }
            if gapOld.count > gapNew.count {
                let absorber = gapNew.last ?? previousNew
                for removed in gapOld[gapNew.count...] {
                    absorbedBy[removed] = absorber
                }
            }
            if oldIndex < old.count {
                assignment[newIndex] = oldIndex
            }
            previousOld = oldIndex
            previousNew = newIndex
        }
        return Alignment(assignment: assignment, absorbedBy: absorbedBy)
    }

    /// Index pairs of the longest common subsequence of two string arrays.
    static func longestCommonSubsequence(_ lhs: [String], _ rhs: [String]) -> [(Int, Int)] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                table[i][j] = lhs[i] == rhs[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            if lhs[i] == rhs[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
