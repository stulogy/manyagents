import Foundation

enum ProjectNaming {
    /// Just the last path component (lowercased), trimmed of trailing slashes.
    static func name(forCwd cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return (trimmed as NSString).lastPathComponent
    }

    /// "~/Sites/foo" form, for display.
    static func prettyCwd(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }
}
