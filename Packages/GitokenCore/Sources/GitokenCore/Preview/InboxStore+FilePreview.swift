import Foundation

extension InboxStore {
    /// The file preview store, created once. It shares the service and clock, and posts replies through
    /// `reply(to:body:inReplyTo:)`.
    public func makeFilePreviewStore() -> FilePreviewStore {
        if let filePreviewStore { return filePreviewStore }
        guard let previews = service as? any FilePreviewService else {
            preconditionFailure("\(type(of: service)) does not implement FilePreviewService")
        }
        let store = FilePreviewStore(
            service: previews, now: now,
            postReply: { [weak self] (threadID: ThreadID, body: String, parent: ReviewComment?) async throws(GitHubError) in
                guard let self else { throw .http(status: 422, message: "The inbox is no longer available.") }
                try await self.reply(to: threadID, body: body, inReplyTo: parent)
            })
        filePreviewStore = store
        return store
    }
}
