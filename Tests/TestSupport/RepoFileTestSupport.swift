import Foundation

func repositoryRoot(from filePath: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(filePath)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func repositoryFile(_ relativePath: String, from filePath: StaticString = #filePath) -> URL {
    repositoryRoot(from: filePath).appendingPathComponent(relativePath)
}

func repositoryTextFile(_ relativePath: String, from filePath: StaticString = #filePath) throws -> String {
    try String(contentsOf: repositoryFile(relativePath, from: filePath), encoding: .utf8)
}
