import Foundation

public struct Path: Sendable, Hashable, Codable {
    public static var separator: String {
#if os(Windows)
        return "\\"
#else
        return "/"
#endif
    }

    public static var currentDirectoryPath: Path {
        Path(pathString: FileManager.default.currentDirectoryPath)
    }

    let components: [String]
    let isAbsolute: Bool

    public var `extension`: String? {
        guard let lastComponent = components.last else { return nil }
        if lastComponent.contains(".") == false { return nil }
        return lastComponent.components(separatedBy: ".").last
    }

    public var parentDirectory: Path {
        Path(components: components.dropLast(1), isAbsolute: isAbsolute)
    }

    public var url: URL {
        URL(fileURLWithPath: absolutePathString)
    }

    public var pathString: String {
        (isAbsolute ? Path.separator : "") + components.joined(separator: Path.separator)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: absolutePathString)
    }

    public var isDirectory: Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: absolutePathString, isDirectory: &isDir)
        return isDir.boolValue
    }

    private var absolutePathString: String {
        if isAbsolute {
            return pathString
        } else {
            return try! Path.currentDirectoryPath.appending(path: self).pathString
        }
    }

    public init(components: [String], isAbsolute: Bool) {
        self.components = components
        self.isAbsolute = isAbsolute
    }

    public init(pathString: String) {
        self.init(components: pathString.components(separatedBy: Path.separator).compactMap {
            if $0.isEmpty { return nil }
            return $0
        }, isAbsolute: pathString.hasPrefix("/"))
    }

    public init(url: URL) {
        self.init(pathString: url.path)
    }

    public func appending(components: String...) -> Path {
        Path(components: self.components + components, isAbsolute: isAbsolute)
    }

    public func appending(path: Path) throws -> Path {
        guard path.isAbsolute == false else {
            throw PathError.triedToAddAbsolutePathToAnother
        }
        return Path(components: self.components + path.components, isAbsolute: self.isAbsolute)
    }
}

enum PathError: Error {
    case triedToAddAbsolutePathToAnother
}
