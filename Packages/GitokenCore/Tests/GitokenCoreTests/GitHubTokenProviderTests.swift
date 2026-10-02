import Foundation
import Testing
@testable import GitokenCore

@Suite struct GitHubTokenProviderTests {
    /// A scratch directory holding a fake `gh` executable with the given shell body.
    private struct FakeGH {
        let directory: URL
        var executable: String { directory.appendingPathComponent("gh").path }
        var log: URL { directory.appendingPathComponent("invocations.log") }

        init(_ body: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitoken-gh-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = "#!/bin/sh\necho \"$@\" >> '\(directory.appendingPathComponent("invocations.log").path)'\n\(body)\n"
            try script.write(toFile: directory.appendingPathComponent("gh").path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("gh").path)
        }

        var invocations: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func returnsTrimmedTokenAndCachesUntilInvalidated() async throws {
        let gh = try FakeGH("printf 'gho_fixtureToken123\\n'")
        defer { gh.remove() }
        let provider = GHCLITokenProvider(searchPaths: ["/nonexistent/gh", gh.executable], environment: [:])

        #expect(try await provider.token() == "gho_fixtureToken123")
        #expect(try await provider.token() == "gho_fixtureToken123")
        #expect(gh.invocations == ["auth token --hostname github.com"], "second call must hit the cache")

        await provider.invalidate()
        #expect(try await provider.token() == "gho_fixtureToken123")
        #expect(gh.invocations.count == 2)
    }

    @Test func concurrentCallersShareOneGhRun() async throws {
        let gh = try FakeGH("sleep 0.3; echo gho_shared")
        defer { gh.remove() }
        let provider = GHCLITokenProvider(searchPaths: [gh.executable], environment: [:])

        async let a = provider.token()
        async let b = provider.token()
        let tokens = try await [a, b]

        #expect(tokens == ["gho_shared", "gho_shared"])
        #expect(gh.invocations.count == 1)
    }

    @Test func failingGhMapsToNotLoggedInWithItsMessage() async throws {
        let gh = try FakeGH("echo 'You are not logged into any GitHub hosts. To log in, run: gh auth login' >&2\nexit 1")
        defer { gh.remove() }
        let provider = GHCLITokenProvider(searchPaths: [gh.executable], environment: [:])

        await #expect(throws: AuthError.notLoggedIn(detail: "You are not logged into any GitHub hosts. To log in, run: gh auth login")) {
            try await provider.token()
        }
    }

    @Test func failureIsNotCached() async throws {
        let gh = try FakeGH("exit 4")
        defer { gh.remove() }
        let provider = GHCLITokenProvider(searchPaths: [gh.executable], environment: [:])
        await #expect(throws: AuthError.notLoggedIn(detail: "gh auth token exited with status 4")) { try await provider.token() }
        await #expect(throws: AuthError.self) { try await provider.token() }
        #expect(gh.invocations.count == 2)
    }

    @Test func emptyOutputIsNotLoggedIn() async throws {
        let gh = try FakeGH("exit 0")
        defer { gh.remove() }
        let provider = GHCLITokenProvider(searchPaths: [gh.executable], environment: [:])
        await #expect(throws: AuthError.notLoggedIn(detail: "gh auth token printed no token")) { try await provider.token() }
    }

    @Test func missingExecutableReportsEverySearchedPath() async throws {
        let provider = GHCLITokenProvider(
            searchPaths: ["/nonexistent/a/gh", "/nonexistent/b/gh"], environment: ["PATH": "/nonexistent/c:/nonexistent/a"]
        )
        await #expect(throws: AuthError.ghNotInstalled(searched: ["/nonexistent/a/gh", "/nonexistent/b/gh", "/nonexistent/c/gh"])) {
            try await provider.token()
        }
    }

    @Test func findsGhThroughPATHWhenSearchPathsMiss() async throws {
        let gh = try FakeGH("echo gho_fromPATH")
        defer { gh.remove() }
        let provider = GHCLITokenProvider(searchPaths: ["/nonexistent/gh"], environment: ["PATH": "/nonexistent/bin:\(gh.directory.path)"])
        #expect(try await provider.token() == "gho_fromPATH")
    }

    @Test func hungGhTimesOut() async throws {
        let gh = try FakeGH("exec sleep 5")
        defer { gh.remove() }
        let provider = GHCLITokenProvider(searchPaths: [gh.executable], environment: [:], timeout: 0.3)
        let started = Date()
        await #expect(throws: AuthError.notLoggedIn(detail: "gh auth token did not finish within 0.3 seconds")) {
            try await provider.token()
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
