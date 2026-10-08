import GitokenCore
import SwiftUI

struct SearchRowID: Hashable {
    let sectionID: UUID
    let itemID: SearchItemID
}

enum InboxRowID: Hashable {
    case notification(ThreadID)
    case search(SearchRowID)
}

extension NotchModel {
    func customItems(in sectionID: UUID) -> [SearchItem] {
        store.customSections.items(in: sectionID).filter {
            searchQuery.matches($0, isUnseen: store.customSections.isUnseen($0))
        }
    }

    var keyboardRows: [InboxRowID] {
        let custom = settings.customSections.filter { !$0.isCollapsed }.flatMap { section in
            customItems(in: section.id).map {
                InboxRowID.search(SearchRowID(sectionID: section.id, itemID: $0.id))
            }
        }
        return custom + listRows.map { .notification($0.id) }
    }

    var listSelection: InboxRowID? {
        if let selectedSearchRow { return .search(selectedSearchRow) }
        return selectedRow.map(InboxRowID.notification)
    }

    func selectListRow(_ row: InboxRowID?) {
        switch row {
        case .notification(let id): selectedRow = id
        case .search(let id):
            selectedSearchRow = id
            closePreview()
        case nil:
            selectedRow = nil
            selectedSearchRow = nil
        }
    }

    func activateListSelection() {
        switch listSelection {
        case .notification(let id): open(.conversation(id))
        case .search(let row):
            if let item = searchItem(row.itemID) { openSearch(item) }
        case nil: break
        }
    }

    func toggleCustomSection(_ id: UUID) {
        withAnimation(motion.open) {
            store.updateSettings { settings in
                guard let index = settings.customSections.firstIndex(where: { $0.id == id }) else { return }
                settings.customSections[index].isCollapsed.toggle()
            }
        }
        if let selection = listSelection, !keyboardRows.contains(selection) { selectListRow(keyboardRows.first) }
    }

    func dismissSearch(_ item: SearchItem) {
        let index = listSelection.flatMap { keyboardRows.firstIndex(of: $0) }
        withAnimation(motion.open) { store.customSections.dismiss(item) }
        if case .searchConversation(let id) = route, id == item.id { open(.list) }
        let rows = keyboardRows
        if let selection = listSelection, !rows.contains(selection) {
            selectListRow(rows.isEmpty ? nil : rows[min(index ?? 0, rows.count - 1)])
        }
        showToast("Dismissed from custom sections") { [weak self] in
            self?.store.customSections.restore(item.id)
        }
    }
}
