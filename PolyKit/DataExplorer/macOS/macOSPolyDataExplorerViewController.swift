//
//  macOSPolyDataExplorerViewController.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

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

        override public func loadView() {
            view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        override public func viewDidLoad() {
            super.viewDidLoad()
            self.setupSearchField()
            self.setupTableView()
            self.setupColumns()
        }

        // MARK: Public Methods

        public func reloadData() {
            self.setupColumns()

            // Refresh integrity analysis
            self.dataSource.invalidateIntegrityCache()
            _ = self.dataSource.getIntegrityReport()

            // Fetch records
            self.records = self.dataSource.fetchCurrentRecords()

            self.tableView.reloadData()
            self.updateSortIndicator()

            // Clear selection
            self.tableView.deselectAll(nil)
            self.notifySelectionChanged()
        }

        public func reloadCurrentSelection() {
            let selectedRow = self.tableView.selectedRow

            self.records = self.dataSource.fetchCurrentRecords()
            self.tableView.reloadData()

            if selectedRow >= 0, selectedRow < self.tableView.numberOfRows {
                self.tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            }
        }

        // MARK: Setup

        private func setupSearchField() {
            self.searchField = NSSearchField()
            self.searchField.translatesAutoresizingMaskIntoConstraints = false
            self.searchField.placeholderString = "Search..."
            self.searchField.target = self
            self.searchField.action = #selector(self.searchFieldChanged(_:))

            view.addSubview(self.searchField)

            NSLayoutConstraint.activate([
                self.searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
                self.searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                self.searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            ])
        }

        private func setupTableView() {
            self.tableView = NSTableView()
            self.tableView.style = .inset
            self.tableView.usesAlternatingRowBackgroundColors = true
            self.tableView.allowsMultipleSelection = true
            self.tableView.allowsColumnReordering = true
            self.tableView.allowsColumnResizing = true
            self.tableView.allowsColumnSelection = false
            self.tableView.columnAutoresizingStyle = .noColumnAutoresizing
            self.tableView.delegate = self
            self.tableView.dataSource = self
            self.tableView.target = self
            self.tableView.doubleAction = #selector(self.tableViewDoubleClicked(_:))

            // Set up context menu
            let menu = NSMenu()
            menu.delegate = self
            self.tableView.menu = menu

            self.scrollView = NSScrollView()
            self.scrollView.translatesAutoresizingMaskIntoConstraints = false
            self.scrollView.documentView = self.tableView
            self.scrollView.hasVerticalScroller = true
            self.scrollView.hasHorizontalScroller = true
            self.scrollView.autohidesScrollers = true
            self.scrollView.borderType = .noBorder

            view.addSubview(self.scrollView)

            NSLayoutConstraint.activate([
                self.scrollView.topAnchor.constraint(equalTo: self.searchField.bottomAnchor, constant: 8),
                self.scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                self.scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                self.scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        private func setupColumns() {
            // Remove existing columns
            while !self.tableView.tableColumns.isEmpty {
                self.tableView.removeTableColumn(self.tableView.tableColumns[0])
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

                self.tableView.addTableColumn(column)
            }

            self.updateSortIndicator()
        }

        private func updateSortIndicator() {
            // Clear all sort indicators
            for column in self.tableView.tableColumns {
                self.tableView.setIndicatorImage(nil, in: column)
            }

            let sortFieldID = self.dataSource.currentSortFieldID
            let ascending = self.dataSource.currentSortAscending

            if let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == sortFieldID }) {
                let image = NSImage(
                    systemSymbolName: ascending ? "chevron.up" : "chevron.down",
                    accessibilityDescription: ascending ? "Ascending" : "Descending",
                )
                self.tableView.setIndicatorImage(image, in: column)
            }
        }

        @objc private func searchFieldChanged(_ sender: NSSearchField) {
            self.dataSource.setSearchText(sender.stringValue)
            self.reloadData()
        }

        @objc private func tableViewDoubleClicked(_: Any) {
            // Double-click could open a more detailed editor in the future
        }

        private func notifySelectionChanged() {
            let selectedIndexes = self.tableView.selectedRowIndexes

            // Multi-select: show empty state
            if selectedIndexes.count != 1 {
                self.delegate?.tableViewController(self, didSelectRecord: nil)
                return
            }

            let selectedRow = selectedIndexes.first!

            if selectedRow < self.records.count {
                self.delegate?.tableViewController(self, didSelectRecord: self.records[selectedRow])
            } else {
                self.delegate?.tableViewController(self, didSelectRecord: nil)
            }
        }

        // MARK: Context Menu Actions

        @objc private func copyCellValue(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

        @objc private func deleteSelectedRecords(_: NSMenuItem) {
            let selectedIndexes = self.tableView.selectedRowIndexes
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
                for index in indexes.reversed() where index < self.records.count {
                    await dataSource.deleteRecord(records[index])
                    deletedCount += 1
                }

                self.reloadData()
                self.delegate?.tableViewController(self, didDeleteRecords: deletedCount)
            }
        }
    }

    // MARK: - NSTableViewDataSource

    extension macOSPolyDataExplorerViewController: NSTableViewDataSource {
        public func numberOfRows(in _: NSTableView) -> Int {
            self.records.count
        }

        public func tableView(_: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
            guard
                let sortDescriptor = tableView.sortDescriptors.first,
                let key = sortDescriptor.key else { return }

            let ascending = sortDescriptor.ascending
            self.dataSource.setSort(fieldID: key, ascending: ascending)
            self.reloadData()
        }
    }

    // MARK: - NSTableViewDelegate

    extension macOSPolyDataExplorerViewController: NSTableViewDelegate {
        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard
                let column = tableColumn,
                let entity = dataSource.currentEntity,
                row < records.count else { return nil }

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
            let record = self.records[row]

            cell.stringValue = entity.cellValue(record, columnIndex)

            if let color = entity.cellColor(record, columnIndex, dataSource.getIntegrityReport()) {
                cell.textColor = color
            } else {
                cell.textColor = .labelColor
            }

            return cell
        }

        public func tableViewSelectionDidChange(_: Notification) {
            self.notifySelectionChanged()
        }

        public func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
            20
        }
    }

    // MARK: - NSMenuDelegate

    extension macOSPolyDataExplorerViewController: NSMenuDelegate {
        public func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()

            let clickedRow = self.tableView.clickedRow
            guard clickedRow >= 0 else { return }

            // If clicked row is not in selection, select it (replacing selection)
            if !self.tableView.selectedRowIndexes.contains(clickedRow) {
                self.tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }

            let selectedIndexes = self.tableView.selectedRowIndexes
            let clickedColumn = self.tableView.clickedColumn

            guard let entity = dataSource.currentEntity else { return }

            // Copy Cell Value (only if clicked on a specific cell)
            if clickedColumn >= 0, clickedColumn < entity.columnCount, clickedRow < self.records.count {
                let cellValue = entity.cellValue(self.records[clickedRow], clickedColumn)
                let columnTitle = entity.columnTitle(clickedColumn)
                if !cellValue.isEmpty, cellValue != "—" {
                    let copyItem = NSMenuItem(
                        title: "Copy \"\(columnTitle)\"",
                        action: #selector(copyCellValue(_:)),
                        keyEquivalent: "",
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
                keyEquivalent: "",
            )
            deleteItem.target = self
            menu.addItem(deleteItem)
        }
    }

#endif // os(macOS)
