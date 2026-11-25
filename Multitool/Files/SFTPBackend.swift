import Foundation
import Citadel
import NIOCore

final class SFTPBackend: RemoteFileBackend {
    private let connection: ShellConnection
    private let sftp: SFTPClient
    private static let chunkSize: UInt32 = 32_768

    var shell: ShellConnection? { connection }

    private init(connection: ShellConnection, sftp: SFTPClient) {
        self.connection = connection
        self.sftp = sftp
    }

    @MainActor
    static func open(host: ServerHost, store: AppStore, password: String?) async throws -> SFTPBackend {
        let connection = try await SSHConnector.connect(host, store: store, password: password)
        do {
            let sftp = try await connection.client.openSFTP()
            return SFTPBackend(connection: connection, sftp: sftp)
        } catch {
            await connection.close()
            throw error
        }
    }

    func homeDirectory() async throws -> String {
        try await sftp.getRealPath(atPath: ".")
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        let names = try await sftp.listDirectory(atPath: path)
        var files: [RemoteFile] = []
        for name in names {
            for component in name.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }
                let fullPath = RemotePath.join(path, filename)
                let attributes = component.attributes
                let longTokens = component.longname.split(separator: " ", omittingEmptySubsequences: true)

                var isDirectory: Bool
                var isSymlink: Bool
                if let mode = attributes.permissions {
                    let type = mode & 0o170000
                    isDirectory = type == 0o040000
                    isSymlink = type == 0o120000
                } else {
                    isDirectory = component.longname.hasPrefix("d")
                    isSymlink = component.longname.hasPrefix("l")
                }
                if isSymlink, let target = try? await sftp.getAttributes(at: fullPath), let targetMode = target.permissions {
                    isDirectory = (targetMode & 0o170000) == 0o040000
                }

                files.append(RemoteFile(
                    name: filename,
                    path: fullPath,
                    isDirectory: isDirectory,
                    isSymlink: isSymlink,
                    size: attributes.size,
                    modified: attributes.accessModificationTime?.modificationTime,
                    permissions: attributes.permissions.map { $0 & 0o7777 },
                    owner: longTokens.count >= 9 ? String(longTokens[2]) : nil,
                    group: longTokens.count >= 9 ? String(longTokens[3]) : nil
                ))
            }
        }
        return files
    }

    func download(_ path: String, to local: URL, progress: @escaping (Int64) -> Void) async throws {
        let file = try await sftp.openFile(filePath: path, flags: .read)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let handle = try FileHandle(forWritingTo: local)
        let expectedSize = try? await file.readAttributes().size
        var offset: UInt64 = 0
        do {
            while true {
                if let expectedSize, offset >= expectedSize { break }
                let chunk: ByteBuffer
                do {
                    chunk = try await file.read(from: offset, length: Self.chunkSize)
                } catch {
                    if Self.isEndOfFile(error) { break }
                    throw error
                }
                let count = chunk.readableBytes
                if count == 0 { break }
                try handle.write(contentsOf: Array(chunk.readableBytesView))
                offset += UInt64(count)
                progress(Int64(offset))
            }
            try handle.close()
            try await file.close()
        } catch {
            try? handle.close()
            try? await file.close()
            throw error
        }
    }

    func upload(_ local: URL, to path: String, progress: @escaping (Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        var offset: UInt64 = 0
        do {
            while let data = try handle.read(upToCount: Int(Self.chunkSize)), !data.isEmpty {
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                progress(Int64(offset))
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    func delete(_ file: RemoteFile) async throws {
        if file.isDirectory && !file.isSymlink {
            do {
                try await sftp.rmdir(at: file.path)
            } catch {
                _ = try await connection.run("rm -rf -- \(ShellQuote.quote(file.path))")
            }
        } else {
            try await sftp.remove(at: file.path)
        }
    }

    func createDirectory(_ path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    func rename(_ from: String, to: String) async throws {
        try await sftp.rename(at: from, to: to)
    }

    func setPermissions(_ path: String, mode: UInt32) async throws {
        do {
            var attributes = SFTPFileAttributes()
            attributes.permissions = mode
            try await sftp.setAttributes(at: path, to: attributes)
        } catch {
            _ = try await connection.run("chmod \(String(mode, radix: 8)) -- \(ShellQuote.quote(path))")
        }
    }

    func close() async {
        try? await sftp.close()
        await connection.close()
    }

    private static func isEndOfFile(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("eof") || description.contains("end of file") || description.contains("endoffile")
    }
}
