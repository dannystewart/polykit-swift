#if os(macOS)

    import AppKit
    import SwiftData

    // MARK: - macOSPolyDataExplorerViewControllerDelegate

    /// Delegate protocol for the macOS Data Explorer table view controller.
    @MainActor
    public protocol macOSPolyDataExplorerViewControllerDelegate: AnyObject {
        func tableViewController(_ controller: macOSPolyDataExplorerViewController, didSelectRecord record: AnyObject?)
        func tableViewController(_ controller: macOSPolyDataExplorerViewController, didDeleteRecords count: Int)
    }

    // MARK: - macOSPolyDataExplorerViewController

    /// Table view controller displaying entity records with sortable columns.
    @MainActor
    public final class macOSPolyDataExplorerViewController: NSViewController {
        // MARK: Properties

        public weak var delegate: macOSPolyDataExplorerViewControllerDelegate?

        private let dataSource: PolyDataExplorerDataSource
        private var records: [AnyObject] = []

        private var tableView: NSTableView!
        private var scrollView: NSScrollView!
        private var searchField: NSSearchField!

        // MARK: Initialization

        public init(dataSource: PolyDataExplorerDataSource) {
            self.dataSource = dataSource
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Lifecycle

        override public func loadView() {
            view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        override public func viewDidLoad() {
            super.viewDidLoad()
            setupSearchField()
            setupTableView()
            setupColumns()
        }

        // MARK: Public Methods

        public func reloadData() {
            setupColumns()

            // Refresh integrity analysis
            dataSource.invalidateIntegrityCache()
            _ = dataSource.getIntegrityReport()

            // Fetch records
            records = dataSource.fetchCurrentRecords()

            tableView.reloadData()
            updateSortIndicator()

            // Clear selection
            tableView.deselectAll(nil)
            notifySelectionChanged()
        }

        public func reloadCurrentSelection() {
            let selectedRow = tableView.selectedRow

            records = dataSource.fetchCurrentRecords()
            tableView.reloadData()

            if selectedRow >= 0, selectedRow < tableView.numberOfRows {
                tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            }
        }

        // MARK: Setup

        private func setupSearchField() {
            searchField = NSSearchField()
            searchField.translatesAutoresizingMaskIntoConstraints = false
            searchField.placeholderString = "Search..."
            searchField.target = self
            searchField.action = #selector(searchFieldChanged(_:))

            view.addSubview(searchField)

            NSLayoutConstraint.activate([
                searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
                searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            ])
        }

        private func setupTableView() {
            tableView = NSTableView()
            tableView.style = .inset
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnReordering = true
            tableView.allowsColumnResizing = true
            tableView.allowsColumnSelection = false
            tableView.columnAutoresizingStyle = .noColumnAutoresizing
            tableView.delegate = self
            tableView.dataSource = self
            tableView.target = self
            tableView.doubleAction = #selector(tableViewDoubleClicked(_:))

            // Set up context menu
            let menu = NSMenu()
            menu.delegate = self
            tableView.menu = menu

            scrollView = NSScrollView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder

            view.addSubview(scrollView)

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        private func setupColumns() {
            // Remove existing columns
            while !tableView.tableColumns.isEmpty {
                tableView.removeTableColumn(tableView.tableColumns[0])
            }

            guard let entity = dataSource.currentEntity else { return }

            for i in 0 ..< entity.columnCount {
                let columnID = entity.columnID(i)
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnID))
                column.title = entity.columnTitle(i)
                column.width = entity.columnWidth(i)
                column.minWidth = entity.columnMinWidth(i)
                column.maxWidth = entity.columnMaxWidth(i)
                column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)

                // Make column sortable if applicable
                if entity.columnIsSortable(i) {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: columnID, ascending: true)
                }

                tableView.addTableColumn(column)
            }

            updateSortIndicator()
        }

        private func updateSortIndicator() {
            // Clear all sort indicators
            for column in tableView.tableColumns {
                tableView.setIndicatorImage(nil, in: column)
            }

            let sortFieldID = dataSource.currentSortFieldID
            let ascending = dataSource.currentSortAscending

            if let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == sortFieldID }) {
                let image = NSImage(
                    systemSymbolName: ascending ? "chevron.up" : "chevron.down",
                    accessibilityDescription: ascending ? "Ascending" : "Descending"
                )
                tableView.setIndicatorImage(image, in: column)
            }
        }

        @objc private func searchFieldChanged(_ sender: NSSearchField) {
            dataSource.setSearchText(sender.stringValue)
            reloadData()
        }

        @objc private func tableViewDoubleClicked(_: Any) {
            // Double-click could open a more detailed editor in the future
        }

        private func notifySelectionChanged() {
            let selectedIndexes = tableView.selectedRowIndexes

            // Multi-select: show empty state
            if selectedIndexes.count != 1 {
                delegate?.tableViewController(self, didSelectRecord: nil)
                return
            }

            let selectedRow = selectedIndexes.first!

            if selectedRow < records.count {
                delegate?.tableViewController(self, didSelectRecord: records[selectedRow])
            } else {
                delegate?.tableViewController(self, didSelectRecord: nil)
            }
        }

        // MARK: Context Menu Actions

        @objc private func copyCellValue(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

        @objc private func deleteSelectedRecords(_: NSMenuItem) {
            let selectedIndexes = tableView.selectedRowIndexes
            guard !selectedIndexes.isEmpty else { return }

            let count = selectedIndexes.count
            guard let entity = dataSource.currentEntity else { return }
            let entityName = entity.displayName.lowercased()
            let itemWord = count == 1 ? String(entityName.dropLast()) : entityName

            let alert = NSAlert()
            alert.messageText = "Delete \(count) \(itemWord)?"
            alert.informativeText = "This action cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true

            guard let window = view.window else { return }

            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.performDeletion(at: selectedIndexes)
            }
        }

        private func performDeletion(at indexes: IndexSet) {
            var deletedCount = 0

            Task {
                for index in indexes.reversed() where index < records.count {
                    await dataSource.deleteRecord(records[index])
                    deletedCount += 1
                }

                reloadData()
                delegate?.tableViewController(self, didDeleteRecords: deletedCount)
            }
        }
    }

    // MARK: - NSTableViewDataSource

    extension macOSPolyDataExplorerViewController: NSTableViewDataSource {
        public func numberOfRows(in _: NSTableView) -> Int {
            records.count
        }

        public func tableView(_: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
            guard let sortDescriptor = tableView.sortDescriptors.first,
                  let key = sortDescriptor.key else { return }

            let ascending = sortDescriptor.ascending
            dataSource.setSort(fieldID: key, ascending: ascending)
            reloadData()
        }
    }

    // MARK: - NSTableViewDelegate

    extension macOSPolyDataExplorerViewController: NSTableViewDelegate {
        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn,
                  let entity = dataSource.currentEntity,
                  row < records.count else { return nil }

            let identifier = column.identifier
            let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")

            let cell: NSTextField
            if let existingCell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
                cell = existingCell
            } else {
                cell = NSTextField()
                cell.identifier = cellIdentifier
                cell.isBordered = false
                cell.drawsBackground = false
                cell.isEditable = false
                cell.lineBreakMode = .byTruncatingTail
                cell.font = .systemFont(ofSize: 11)
            }

            // Find column index
            let columnIndex = tableView.tableColumns.firstIndex(of: column) ?? 0
            let record = records[row]

            cell.stringValue = entity.cellValue(record, columnIndex)

            if let color = entity.cellColor(record, columnIndex, dataSource.getIntegrityReport()) {
                cell.textColor = color
            } else {
                cell.textColor = .labelColor
            }

            return cell
        }

        public func tableViewSelectionDidChange(_: Notification) {
            notifySelectionChanged()
        }

        public func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
            20
        }
    }

    // MARK: - NSMenuDelegate

    extension macOSPolyDataExplorerViewController: NSMenuDelegate {
        public func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()

            let clickedRow = tableView.clickedRow
            guard clickedRow >= 0 else { return }

            // If clicked row is not in selection, select it (replacing selection)
            if !tableView.selectedRowIndexes.contains(clickedRow) {
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }

            let selectedIndexes = tableView.selectedRowIndexes
            let clickedColumn = tableView.clickedColumn

            guard let entity = dataSource.currentEntity else { return }

            // Copy Cell Value (only if clicked on a specific cell)
            if clickedColumn >= 0, clickedColumn < entity.columnCount, clickedRow < records.count {
                let cellValue = entity.cellValue(records[clickedRow], clickedColumn)
                let columnTitle = entity.columnTitle(clickedColumn)
                if !cellValue.isEmpty, cellValue != "—" {
                    let copyItem = NSMenuItem(
                        title: "Copy \"\(columnTitle)\"",
                        action: #selector(copyCellValue(_:)),
                        keyEquivalent: ""
                    )
                    copyItem.target = self
                    copyItem.representedObject = cellValue
                    menu.addItem(copyItem)
                    menu.addItem(.separator())
                }
            }

            // Delete item
            let deleteTitle = selectedIndexes.count == 1 ? "Delete" : "Delete \(selectedIndexes.count) Items"
            let deleteItem = NSMenuItem(
                title: deleteTitle,
                action: #selector(deleteSelectedRecords(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            menu.addItem(deleteItem)
        }
    }

#endif // os(macOS)
