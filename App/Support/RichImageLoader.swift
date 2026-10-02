import AppKit
import GitokenCore

/// Shared loader for images in comment bodies: decoded images stay in memory, bytes in an on-disk URLCache.
/// Each `RichImage` is tried variant by variant (dark/light `<source>`, then `<img src>`), so an SVG that can't
/// decode falls back to the PNG.
final class RichImageLoader {
    static let shared = RichImageLoader()

    private let memory = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private var failed: Set<URL> = []
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "Gitoken/RichImages", directoryHint: .isDirectory)
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 64 << 20, directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        memory.countLimit = 300
    }

    /// The best variant already in memory, or nil while a preferred variant is still untried.
    func cached(_ image: RichImage, dark: Bool) -> NSImage? {
        for url in image.candidates(dark: dark) {
            if let hit = memory.object(forKey: url as NSURL) { return hit }
            if !failed.contains(url) { return nil }
        }
        return nil
    }

    func load(_ image: RichImage, dark: Bool) async -> NSImage? {
        for url in image.candidates(dark: dark) {
            if let loaded = await load(url) { return loaded }
        }
        return nil
    }

    private func load(_ url: URL) async -> NSImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return await running.value }
        let session = session
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            guard let image = NSImage(data: data), image.isValid, !image.representations.isEmpty,
                  image.size.width > 0, image.size.height > 0
            else { return nil }
            return image
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            memory.setObject(result, forKey: url as NSURL)
        } else {
            failed.insert(url)
        }
        return result
    }
}
