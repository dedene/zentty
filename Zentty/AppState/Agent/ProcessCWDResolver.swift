import Darwin

enum ProcessCWDResolver {
    static func workingDirectory(for pid: Int32) -> String? {
        guard pid > 0 else {
            return nil
        }

        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard result == Int32(size) else {
            return nil
        }

        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cPath in
                let path = String(cString: cPath)
                return path.isEmpty ? nil : path
            }
        }
    }
}
