import Foundation

struct RemoteFile: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64?
    let modified: Date?
    let permissions: UInt32?
    let owner: String?
    let group: String?

    init(name: String, path: String, isDirectory: Bool, isSymlink: Bool = false, size: UInt64? = nil,
         modified: Date? = nil, permissions: UInt32? = nil, owner: String? = nil, group: String? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    var permissionString: String {
        guard let permissions else { return "" }
        let flags: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        let type: Character = isSymlink ? "l" : (isDirectory ? "d" : "-")
        return String(type) + String(flags.map { permissions & $0.0 != 0 ? $0.1 : "-" })
    }

    var detailLine: String {
        var parts: [String] = []
        if !permissionString.isEmpty { parts.append(permissionString) }
        if !isDirectory, let size { parts.append(Fmt.bytes(size)) }
        if let modified { parts.append(Fmt.date(modified)) }
        if let owner { parts.append(owner) }
        return parts.joined(separator: " · ")
    }

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "conf", "cfg", "ini", "env", "json", "yaml", "yml", "toml", "xml",
        "html", "htm", "css", "scss", "js", "mjs", "ts", "tsx", "jsx", "vue", "php", "py", "rb", "go", "rs",
        "java", "kt", "swift", "c", "h", "cpp", "hpp", "cs", "sh", "bash", "zsh", "fish", "service", "timer",
        "socket", "sql", "csv", "properties", "gradle", "lua", "pl", "dockerfile", "gitignore", "htaccess",
        "nginx", "rules", "list", "lock", "tf", "hcl", "srt", "vim",
    ]

    var isLikelyText: Bool {
        if isDirectory { return false }
        if RemoteFile.textExtensions.contains(fileExtension) { return true }
        let lower = name.lowercased()
        let known = ["dockerfile", "makefile", "readme", "license", "authorized_keys", "known_hosts", "config",
                     "hosts", "crontab", "profile", ".bashrc", ".zshrc", ".profile", ".bash_profile", ".vimrc",
                     ".env", "caddyfile", "procfile", "vagrantfile", "gemfile"]
        if known.contains(lower) { return true }
        return fileExtension.isEmpty && (size ?? 0) < 512 * 1024
    }

    var iconName: String {
        if isDirectory { return isSymlink ? "folder.badge.gearshape" : "folder.fill" }
        if isSymlink { return "arrow.triangle.turn.up.right.diamond" }
        switch fileExtension {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg": return "photo"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return "film"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg": return "music.note"
        case "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "zst": return "archivebox"
        case "pdf": return "doc.richtext"
        case "sh", "bash", "zsh", "py", "rb", "js", "ts", "go", "rs", "swift", "c", "cpp", "php", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "conf", "ini", "cfg", "env": return "gearshape"
        case "log": return "list.bullet.rectangle"
        case "key", "pem", "crt", "cer", "pub": return "key"
        default: return isLikelyText ? "doc.text" : "doc"
        }
    }
}

enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }

    static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let index = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<index])
        return parent.isEmpty ? "/" : parent
    }

    static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        var result: [(name: String, path: String)] = [("/", "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }
}

protocol RemoteFileBackend: AnyObject {
    var shell: ShellConnection? { get }
    func homeDirectory() async throws -> String
    func list(_ path: String) async throws -> [RemoteFile]
    func download(_ path: String, to local: URL, progress: @escaping (Int64) -> Void) async throws
    func upload(_ local: URL, to path: String, progress: @escaping (Int64) -> Void) async throws
    func delete(_ file: RemoteFile) async throws
    func createDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func setPermissions(_ path: String, mode: UInt32) async throws
    func close() async
}

final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldEmit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(last) >= 0.15 {
            last = now
            return true
        }
        return false
    }
}
