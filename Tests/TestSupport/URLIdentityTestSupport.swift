import Foundation

func normalizedTestFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

func testFileURLsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
    normalizedTestFileURL(lhs).path == normalizedTestFileURL(rhs).path
}
