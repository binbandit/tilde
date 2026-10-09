import Foundation

/// Short ids ("j-n8v3") for jobs, messages and requests, and slugs for names made from text.
public enum IDs {
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    public static func make(_ prefix: String, length: Int = 4) -> String {
        prefix + "-" + String((0..<length).map { _ in alphabet.randomElement()! })
    }

    public static func slug(_ text: String, limit: Int = 32) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : slug + "-" + word
            if next.count > limit { break }
            slug = next
        }
        return slug.isEmpty ? "job" : slug
    }
}
