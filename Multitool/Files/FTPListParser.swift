import Foundation

enum FTPListParser {
    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
    }

    static func parseMLSD(_ text: String, directory: String) -> [RemoteFile] {
        var result: [RemoteFile] = []
        for line in lines(text) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let factsPart = line[..<space]
            let name = String(line[line.index(after: space)...])
            guard !name.isEmpty, name != ".", name != ".." else { continue }

            var facts: [String: String] = [:]
            for fact in factsPart.split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1)
                if pair.count == 2 {
                    facts[pair[0].lowercased()] = String(pair[1])
                }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            if type == "cdir" || type == "pdir" { continue }
            let isSymlink = type.contains("slink") || type.contains("symlink")
            let isDirectory = type == "dir" || type.hasSuffix("=dir")

            result.append(RemoteFile(
                name: name,
                path: RemotePath.join(directory, name),
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: facts["size"].flatMap { UInt64($0) },
                modified: facts["modify"].flatMap(parseMLSDDate),
                permissions: facts["unix.mode"].flatMap { UInt32($0, radix: 8) },
                owner: facts["unix.owner"] ?? facts["unix.ownername"],
                group: facts["unix.group"] ?? facts["unix.groupname"]
            ))
        }
        return result
    }

    private static func parseMLSDDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(value.prefix(14)))
    }

    static func parseLIST(_ text: String, directory: String) -> [RemoteFile] {
        lines(text).compactMap { line -> RemoteFile? in
            if line.hasPrefix("total ") { return nil }
            if let unix = parseUnix(line, directory: directory) { return unix }
            return parseDOS(line, directory: directory)
        }
        .filter { $0.name != "." && $0.name != ".." }
    }

    private static func parseUnix(_ line: String, directory: String) -> RemoteFile? {
        guard let typeChar = line.first, "-dlbcps".contains(typeChar) else { return nil }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 8 else { return nil }

        var monthIndex: Int?
        for index in 3..<min(tokens.count - 2, 7) {
            if months[tokens[index].lowercased()] != nil, UInt64(tokens[index - 1]) != nil {
                monthIndex = index
                break
            }
        }
        guard let mi = monthIndex, let month = months[tokens[mi].lowercased()] else { return nil }
        guard var name = remainder(of: line, afterTokens: mi + 3) else { return nil }

        let isSymlink = typeChar == "l"
        if isSymlink, let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        let day = Int(tokens[mi + 1]) ?? 1
        let modified = makeDate(month: month, day: day, timeOrYear: String(tokens[mi + 2]))

        return RemoteFile(
            name: name,
            path: RemotePath.join(directory, name),
            isDirectory: typeChar == "d",
            isSymlink: isSymlink,
            size: UInt64(tokens[mi - 1]),
            modified: modified,
            permissions: parseMode(tokens[0]),
            owner: String(tokens[2]),
            group: mi - 1 > 3 ? String(tokens[3]) : nil
        )
    }

    private static func parseDOS(_ line: String, directory: String) -> RemoteFile? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 4, tokens[0].contains("-") || tokens[0].contains("/") else { return nil }
        let isDirectory = tokens[2].uppercased() == "<DIR>"
        let size = isDirectory ? nil : UInt64(tokens[2])
        guard isDirectory || size != nil, let name = remainder(of: line, afterTokens: 3) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yy hh:mma"
        let modified = formatter.date(from: "\(tokens[0]) \(tokens[1])")

        return RemoteFile(name: name, path: RemotePath.join(directory, name), isDirectory: isDirectory, size: size, modified: modified)
    }

    private static func remainder(of line: String, afterTokens count: Int) -> String? {
        var index = line.startIndex
        for _ in 0..<count {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
        }
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        guard index < line.endIndex else { return nil }
        return String(line[index...])
    }

    private static func parseMode(_ token: Substring) -> UInt32? {
        let chars = Array(token)
        guard chars.count >= 10 else { return nil }
        let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        var mode: UInt32 = 0
        for (offset, bit) in bits.enumerated() {
            let c = chars[offset + 1]
            if c != "-" && c != "S" && c != "T" && c != "l" {
                mode |= bit
            }
        }
        return mode
    }

    private static func makeDate(month: Int, day: Int, timeOrYear: String) -> Date? {
        var components = DateComponents()
        components.month = month
        components.day = day
        let calendar = Calendar(identifier: .gregorian)
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            components.hour = Int(parts[0])
            components.minute = parts.count > 1 ? Int(parts[1]) : 0
            let now = Date()
            var year = calendar.component(.year, from: now)
            components.year = year
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                year -= 1
                components.year = year
            }
        } else {
            components.year = Int(timeOrYear)
        }
        return calendar.date(from: components)
    }
}
