//
//  iOSPolyDataExplorerEntitiesSidebarViewController.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(iOS)

    import UIKit

    // MARK: - iOSPolyDataExplorerEntitiesSidebarViewController

    /// Entity selector and lightweight filter controls for the iOS Data Explorer.
    ///
    /// On iPad, this serves as the primary (left) column of a triple-column split view.
    @MainActor
    final class iOSPolyDataExplorerEntitiesSidebarViewController: UITableViewController {
        // MARK: Types

        private enum Section: Int, CaseIterable {
            case entities
            case filters
        }

        private enum FilterRow: Int, CaseIterable {
            case issuesOnly
            case clearFilter
        }

        // MARK: Callbacks

        var onSelectEntityIndex: ((Int) -> Void)?
        var onSetIssuesOnly: ((Bool) -> Void)?
        var onClearFilter: (() -> Void)?

        private let dataSource: PolyDataExplorerDataSource

        // MARK: Initialization

        init(dataSource: PolyDataExplorerDataSource) {
            self.dataSource = dataSource
            super.init(style: .insetGrouped)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = "Data Explorer"
            self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        }

        // MARK: UITableViewDataSource

        override func numberOfSections(in _: UITableView) -> Int {
            Section.allCases.count
        }

        override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
            guard let section = Section(rawValue: section) else { return 0 }
            return switch section {
            case .entities: self.dataSource.configuration.entities.count
            case .filters: FilterRow.allCases.count
            }
        }

        override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
            guard let section = Section(rawValue: section) else { return nil }
            return switch section {
            case .entities: "Entities"
            case .filters: "Filters"
            }
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            cell.accessoryView = nil
            cell.accessoryType = .none
            cell.selectionStyle = .default

            guard let section = Section(rawValue: indexPath.section) else { return cell }

            switch section {
            case .entities:
                self.configureEntityCell(cell, index: indexPath.row)
                return cell

            case .filters:
                self.configureFilterCell(cell, row: indexPath.row)
                return cell
            }
        }

        // MARK: UITableViewDelegate

        override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            guard let section = Section(rawValue: indexPath.section) else { return }

            switch section {
            case .entities:
                self.onSelectEntityIndex?(indexPath.row)

            case .filters:
                guard let row = FilterRow(rawValue: indexPath.row) else { return }
                switch row {
                case .issuesOnly:
                    break // handled by switch
                case .clearFilter:
                    self.onClearFilter?()
                }
            }
        }

        // MARK: Public API

        func reloadSidebar() {
            self.tableView.reloadData()
        }

        // MARK: Cell Config

        private func configureEntityCell(_ cell: UITableViewCell, index: Int) {
            guard index >= 0, index < self.dataSource.configuration.entities.count else { return }
            let entity = self.dataSource.configuration.entities[index]

            let report = self.dataSource.getIntegrityReport()
            let issueCounts = report?.issueCountsByEntity ?? [:]
            let issueCount = issueCounts[entity.id] ?? 0

            var config = cell.defaultContentConfiguration()
            config.text = entity.displayName
            config.image = UIImage(systemName: entity.iconName)
            config.imageProperties.tintColor = .label

            if issueCount > 0 {
                config.secondaryText = "\(issueCount) issue\(issueCount == 1 ? "" : "s")"
                config.secondaryTextProperties.color = .systemRed
            } else {
                config.secondaryText = nil
            }

            cell.contentConfiguration = config

            let isSelected = (index == self.dataSource.currentEntityIndex)
            cell.accessoryType = isSelected ? .checkmark : .none
        }

        private func configureFilterCell(_ cell: UITableViewCell, row: Int) {
            guard let row = FilterRow(rawValue: row) else { return }

            switch row {
            case .issuesOnly:
                var config = cell.defaultContentConfiguration()
                config.text = "Show issues only"
                config.secondaryText = nil
                cell.contentConfiguration = config
                cell.selectionStyle = .none

                let toggle = UISwitch()
                toggle.isOn = self.dataSource.showOnlyIssues
                toggle.addTarget(self, action: #selector(self.issuesOnlyToggled(_:)), for: .valueChanged)
                cell.accessoryView = toggle

            case .clearFilter:
                var config = cell.defaultContentConfiguration()
                config.text = "Clear filter"
                config.secondaryText = self.dataSource.currentFilter?.displayText ?? (self.dataSource.showOnlyIssues ? "Issues only" : "None")
                config.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = config

                let canClear = (dataSource.currentFilter != nil) || self.dataSource.showOnlyIssues
                cell.selectionStyle = canClear ? .default : .none
                cell.isUserInteractionEnabled = canClear
                cell.contentView.alpha = canClear ? 1.0 : 0.5
                cell.accessoryType = .none
            }
        }

        @objc private func issuesOnlyToggled(_ sender: UISwitch) {
            self.onSetIssuesOnly?(sender.isOn)
        }
    }

#endif // os(iOS)
