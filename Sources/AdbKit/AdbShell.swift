/// Builds commands for the device's `shell:` service.
///
/// Every argument that is not a literal written in this codebase must go through `quote(_:)`.
/// Never build shell strings any other way.
public enum AdbShell {
    /// Wraps an argument in single quotes, replacing each `'` with `'\''`, so the device shell
    /// passes it through unchanged (spaces, `$`, backticks, newlines, Cyrillic, emoji).
    public static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds `program 'arg1' 'arg2' …`. `program` must be a trusted literal such as `mkdir -p`.
    public static func command(_ program: String, _ arguments: [String]) -> String {
        ([program] + arguments.map(quote)).joined(separator: " ")
    }

    /// Prints `ok` when the shell user can read and enter `path`, otherwise `denied`.
    /// The `shell:` (v1) service returns no exit status, so the result is an echoed marker.
    public static func accessCheck(_ path: String) -> String {
        let quoted = quote(path)
        return "test -r \(quoted) -a -x \(quoted) && echo ok || echo denied"
    }
}
