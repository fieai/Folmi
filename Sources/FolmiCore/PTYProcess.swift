import Darwin

public enum PTYProcess {
    public static func name(of pid: pid_t) -> String? {
        var bytes = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A shell can be at the prompt with jobs running in other process groups.
    public static func backgroundJob(in session: pid_t) -> String? {
        var children = [pid_t](repeating: 0, count: 64)
        let bytes = Int32(children.count * MemoryLayout<pid_t>.stride)
        let count = proc_listchildpids(session, &children, bytes)
        return children.prefix(max(0, Int(count))).first { pid in
            guard pid > 0, getsid(pid) == session else { return false }
            let group = getpgid(pid)
            // Startup scripts can run child commands in the shell's own group before the first prompt.
            return group > 0 && group != session
        }.map { name(of: $0) ?? "程序" }
    }
}
