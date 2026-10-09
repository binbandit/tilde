import Foundation

/// The person tilde works for.
public enum Owner {
    public static var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }
}
