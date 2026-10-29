import Foundation
import Testing
@testable import WMCore

@Suite struct IPCSocketPermissionTests {
    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Without a umask change the socket is created with the process umask until chmod runs, so the directory that
    /// holds it must already be private even when it existed before (created 0755 by an older version or the profile store).
    @Test func existingLooseDirectoryIsMadePrivate() throws {
        let dir = "/tmp/wmipc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fd = try IPCSocket.bindAndListen(dir + "/c.sock")
        defer { close(fd) }
        #expect(mode(dir) == 0o700)
        #expect(mode(dir + "/c.sock") == 0o600)
    }
}
