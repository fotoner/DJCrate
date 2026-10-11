import Foundation

/// hdiutil·diskutil·newfs_msdos를 부르는 곳. 시험은 가짜로 바꾼다(실제 장치에 닿지 않게).
public protocol UsbToolRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data)
}

/// 실제 프로세스로 부른다. stdout·stderr를 끝까지 읽는다(한쪽이 차서 멈추지 않게 stderr는 따로 읽는다)
public struct SystemToolRunner: UsbToolRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let box = ErrorBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, box.data)
    }

    private final class ErrorBox: @unchecked Sendable {
        var data = Data()
    }
}
