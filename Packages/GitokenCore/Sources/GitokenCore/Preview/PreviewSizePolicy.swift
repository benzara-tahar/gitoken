import Foundation

public enum PreviewSizePolicy {
    /// Above this, a file is collapsed until "Load anyway".
    public static let collapseBytes = 1_000_000
    /// Tree-sitter takes ~380 ms for 512 KB of dense TypeScript (release, arm64, off-main); larger files show plain text.
    public static let highlightBytes = 512_000

    private static let generatedNames: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
        "composer.lock", "gemfile.lock", "cargo.lock", "podfile.lock", "poetry.lock", "pipfile.lock", "uv.lock",
        "go.sum", "flake.lock", "mix.lock", "pubspec.lock", "packages.lock.json", "package.resolved",
    ]

    private static let generatedSuffixes = [
        ".lock", ".min.js", ".min.css", ".map", ".designer.cs", ".g.cs", ".g.i.cs", ".generated.cs", ".pb.go",
        ".pb.swift", "_pb2.py", ".snap",
    ]

    /// Lockfiles, minified bundles, source maps, and common codegen outputs.
    public static func isGenerated(path: String) -> Bool {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        return generatedNames.contains(name) || generatedSuffixes.contains { name.hasSuffix($0) }
    }

    public static func shouldCollapse(path: String, byteCount: Int) -> Bool {
        byteCount > collapseBytes || isGenerated(path: path)
    }

    /// Git's heuristic: a NUL byte in the first 8000 bytes.
    public static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }
}
