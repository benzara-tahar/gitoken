import Foundation

extension [TimelineItem] {
    /// The viewer's `content` reaction applied to the description, comment, review, or review comment whose node id is
    /// `subjectID`; nil when nothing here has that id.
    func addingReaction(_ content: ReactionContent, to subjectID: String) -> [TimelineItem]? {
        for index in indices {
            let item = self[index]
            if item.reactionSubjectID == subjectID {
                var items = self
                items[index] = item.with(reactions: item.reactions.adding(content))
                return items
            }
            guard case .review(let state, let body, let comments) = item.payload,
                  let c = comments.firstIndex(where: { $0.id == subjectID }) else { continue }
            var updated = comments
            updated[c] = comments[c].with(reactions: comments[c].reactions.adding(content))
            var items = self
            items[index] = item.with(payload: .review(state: state, body: body, comments: updated))
            return items
        }
        return nil
    }
}
