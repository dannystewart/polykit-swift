//
//  iOSPolyDataExplorerRecordsViewController.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(iOS)

    import UIKit

    // MARK: - iOSPolyDataExplorerRecordsViewController

    /// Records list column for the iOS Data Explorer.
    ///
    /// Displays a table of records for the selected entity type with search, sort, and filtering.
    /// Selection is reported via callbacks so a container (e.g. a split view controller) can
    /// decide how to present details.
    @MainActor
    final class iOSPolyDataExplorerRecordsViewController: UIViewController {
        // MARK: Callbacks

        var onSelectRecord: ((AnyObject) -> Void)?
        var onEntitySelected: ((Int) -> Void)?

        private let dataSource: PolyDataExplorerDataSource
        private var records: [AnyObject] = []

        // UI Components
        private var tableView: UITableView!
        private var searchController: UISearchController!
        private var statsLabel: UILabel!

        private let bannerStack: UIStackView = .init()
        private var filterBanner: UIView?
        private var warningBanner: UIView?

        private let emptyStateLabel: UILabel = .init()

        // MARK: Initialization

        init(dataSource: PolyDataExplorerDataSource) {
            self.dataSource = dataSource
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            self.setupUI()
            self.setupNavigationBar()
            self.setupSearchController()
            self.setupEmptyState()
            self.reloadData()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard self.tableView != nil else { return }
            self.emptyStateLabel.frame = self.tableView.bounds.insetBy(dx: 24, dy: 0)
        }

        // MARK: Public API

        func setSelectedEntityIndex(_ index: Int) {
            self.dataSource.selectEntity(at: index)
            self.reloadData()
        }

        // MARK: Data Loading

        func reloadData() {
            self.dataSource.invalidateIntegrityCache()
            _ = self.dataSource.getIntegrityReport()

            self.records = self.dataSource.fetchCurrentRecords()

            self.tableView.reloadData()
            self.updateStats()
            self.rebuildBanners()
            self.refreshMenus()
            self.updateEmptyState()
        }

        // MARK: Setup

        private func setupUI() {
            view.backgroundColor = .systemGroupedBackground

            // Stats label at top
            self.statsLabel = UILabel()
            self.statsLabel.translatesAutoresizingMaskIntoConstraints = false
            self.statsLabel.font = .systemFont(ofSize: 12)
            self.statsLabel.textColor = .secondaryLabel
            self.statsLabel.textAlignment = .center
            view.addSubview(self.statsLabel)

            // Banner stack (filter and warning banners can both be present).
            self.bannerStack.translatesAutoresizingMaskIntoConstraints = false
            self.bannerStack.axis = .vertical
            self.bannerStack.alignment = .fill
            self.bannerStack.distribution = .fill
            self.bannerStack.spacing = 8
            view.addSubview(self.bannerStack)

            // Table view
            self.tableView = UITableView(frame: .zero, style: .plain)
            self.tableView.translatesAutoresizingMaskIntoConstraints = false
            self.tableView.delegate = self
            self.tableView.dataSource = self
            self.tableView.register(
                iOSPolyDataExplorerCell.self,
                forCellReuseIdentifier: iOSPolyDataExplorerCell.reuseIdentifier,
            )
            // Fixed row height avoids any self-sizing edge cases and is much faster for large datasets.
            self.tableView.rowHeight = 88
            self.tableView.estimatedRowHeight = 88
            view.addSubview(self.tableView)

            NSLayoutConstraint.activate([
                self.statsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                self.statsLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                self.statsLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

                self.bannerStack.topAnchor.constraint(equalTo: self.statsLabel.bottomAnchor, constant: 12),
                self.bannerStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                self.bannerStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

                self.tableView.topAnchor.constraint(equalTo: self.bannerStack.bottomAnchor, constant: 12),
                self.tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                self.tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                self.tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        private func setupEmptyState() {
            self.emptyStateLabel.textAlignment = .center
            self.emptyStateLabel.textColor = .secondaryLabel
            self.emptyStateLabel.numberOfLines = 0
            self.emptyStateLabel.font = .systemFont(ofSize: 14, weight: .regular)
            self.emptyStateLabel.translatesAutoresizingMaskIntoConstraints = true
            self.emptyStateLabel.frame = self.tableView.bounds.insetBy(dx: 24, dy: 0)
            self.emptyStateLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.tableView.backgroundView = self.emptyStateLabel
            self.updateEmptyState()
        }

        private func updateEmptyState() {
            guard let entity = self.dataSource.currentEntity else {
                self.emptyStateLabel.isHidden = false
                self.emptyStateLabel.text = "No entity selected."
                self.tableView.separatorStyle = .none
                return
            }

            let expected = entity.recordCount(self.dataSource.modelContext)
            if self.records.isEmpty {
                self.tableView.separatorStyle = .none

                if expected > 0 {
                    self.emptyStateLabel.text = """
                    No rows fetched for \(entity.displayName).

                    Expected \(expected) record(s) based on count(), but fetch returned 0.
                    """
                } else {
                    self.emptyStateLabel.text = "No \(entity.displayName.lowercased()) found."
                }
                self.emptyStateLabel.isHidden = false
            } else {
                self.emptyStateLabel.isHidden = true
                self.tableView.separatorStyle = .singleLine
            }
        }

        private func setupNavigationBar() {
            title = self.dataSource.configuration.title
            navigationController?.navigationBar.prefersLargeTitles = false

            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(self.handleDone),
            )

            let entityPicker = UIBarButtonItem(
                title: dataSource.currentEntity?.displayName ?? "Entity",
                menu: self.createEntityMenu(),
            )

            let refreshButton = UIBarButtonItem(
                image: UIImage(systemName: "arrow.clockwise"),
                style: .plain,
                target: self,
                action: #selector(handleRefresh),
            )

            // Sort menu
            let sortButton = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down"),
                menu: createSortMenu(),
            )

            var leftItems = [UIBarButtonItem]()
            leftItems.append(entityPicker)
            leftItems.append(refreshButton)

            if !self.dataSource.configuration.toolbarSections.isEmpty {
                let toolsButton = UIBarButtonItem(
                    image: UIImage(systemName: "wrench.and.screwdriver"),
                    menu: createToolsMenu(),
                )
                leftItems.append(toolsButton)
            }

            leftItems.append(sortButton)
            navigationItem.leftBarButtonItems = leftItems
        }

        private func setupSearchController() {
            self.searchController = UISearchController(searchResultsController: nil)
            self.searchController.searchResultsUpdater = self
            self.searchController.obscuresBackgroundDuringPresentation = false
            self.searchController.searchBar.placeholder = "Search..."
            navigationItem.searchController = self.searchController
            definesPresentationContext = true
        }

        @objc private func handleDone() {
            self.dataSource.context.dismiss?()
        }

        @objc private func handleRefresh() {
            self.reloadData()
        }

        @objc private func clearFilter() {
            self.dataSource.clearFilter()
            self.reloadData()
        }

        // MARK: Menus

        private func createEntityMenu() -> UIMenu {
            let report = self.dataSource.getIntegrityReport()
            let issueCounts = report?.issueCountsByEntity ?? [:]
            let currentID = self.dataSource.currentEntity?.id

            let actions = self.dataSource.configuration.entities.enumerated().map { index, entity in
                let issueCount = issueCounts[entity.id] ?? 0
                let title = issueCount > 0 ? "⚠️ \(entity.displayName)" : entity.displayName

                return UIAction(
                    title: title,
                    image: UIImage(systemName: entity.iconName),
                    state: (entity.id == currentID) ? .on : .off,
                ) { [weak self] _ in
                    guard let self else { return }
                    self.onEntitySelected?(index)
                }
            }

            return UIMenu(title: "Entities", children: actions)
        }

        private func createSortMenu() -> UIMenu {
            guard let entity = dataSource.currentEntity else {
                return UIMenu(title: "Sort By", children: [])
            }

            let currentFieldID = self.dataSource.currentSortFieldID
            let ascending = self.dataSource.currentSortAscending

            let actions = (0 ..< entity.sortFieldCount).map { i in
                let fieldID = entity.sortFieldID(i)
                let displayName = entity.sortFieldDisplayName(i)
                let isSelected = fieldID == currentFieldID

                return UIAction(
                    title: displayName,
                    image: isSelected ? UIImage(systemName: ascending ? "chevron.up" : "chevron.down") : nil,
                    state: isSelected ? .on : .off,
                ) { [weak self] _ in
                    self?.dataSource.toggleSort(fieldID: fieldID)
                    self?.reloadData()
                    self?.refreshMenus()
                }
            }

            return UIMenu(title: "Sort By", children: actions)
        }

        private func createToolsMenu() -> UIMenu {
            var menuChildren = [UIMenuElement]()

            for section in self.dataSource.configuration.toolbarSections {
                let sectionActions = section.actions.map { action in
                    UIAction(
                        title: action.title,
                        image: UIImage(systemName: action.iconName),
                        attributes: action.isDestructive ? .destructive : [],
                    ) { [weak self] _ in
                        guard let self else { return }
                        Task {
                            await action.action(self.dataSource.context)
                        }
                    }
                }

                let sectionMenu = UIMenu(title: "", options: .displayInline, children: sectionActions)
                menuChildren.append(sectionMenu)
            }

            return UIMenu(title: "Tools", children: menuChildren)
        }

        private func refreshMenus() {
            guard let leftItems = navigationItem.leftBarButtonItems else { return }

            for item in leftItems {
                if item.image == UIImage(systemName: "arrow.up.arrow.down") {
                    item.menu = self.createSortMenu()
                } else if item.menu?.title == "Entities" {
                    item.title = self.dataSource.currentEntity?.displayName ?? "Entity"
                    item.menu = self.createEntityMenu()
                }
            }
        }

        private func updateStats() {
            guard self.dataSource.configuration.showStats else {
                self.statsLabel.isHidden = true
                return
            }

            self.statsLabel.isHidden = false
            let stats = self.dataSource.fetchStats()
            self.statsLabel.text = stats.formattedString
        }

        private func rebuildBanners() {
            self.filterBanner = nil
            self.warningBanner = nil
            for subview in self.bannerStack.arrangedSubviews {
                self.bannerStack.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }

            if let filterView = buildFilterBannerIfNeeded() {
                self.bannerStack.addArrangedSubview(filterView)
                self.filterBanner = filterView
            }

            if let warningView = buildWarningBannerIfNeeded() {
                self.bannerStack.addArrangedSubview(warningView)
                self.warningBanner = warningView
            }
        }

        private func buildFilterBannerIfNeeded() -> UIView? {
            let showIssuesFilter = self.dataSource.showOnlyIssues
            let regularFilter = self.dataSource.currentFilter

            guard showIssuesFilter || regularFilter != nil else { return nil }

            let banner = UIView()
            banner.translatesAutoresizingMaskIntoConstraints = false
            banner.layer.cornerRadius = 8

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12, weight: .medium)

            if showIssuesFilter {
                banner.backgroundColor = .systemRed.withAlphaComponent(0.1)
                label.text = "Showing only records with issues"
                label.textColor = .systemRed
            } else if let filter = regularFilter {
                banner.backgroundColor = .systemBlue.withAlphaComponent(0.1)
                label.text = "Filter: \(filter.displayText)"
                label.textColor = .systemBlue
            }

            let clearButton = UIButton(type: .system)
            clearButton.translatesAutoresizingMaskIntoConstraints = false
            clearButton.setTitle("Clear", for: .normal)
            clearButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            clearButton.tintColor = showIssuesFilter ? .systemRed : .systemBlue
            clearButton.addTarget(self, action: #selector(self.clearFilter), for: .touchUpInside)

            banner.addSubview(label)
            banner.addSubview(clearButton)

            NSLayoutConstraint.activate([
                banner.heightAnchor.constraint(equalToConstant: 32),

                label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
                label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

                clearButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
                clearButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -8),
            ])

            return banner
        }

        private func buildWarningBannerIfNeeded() -> UIView? {
            guard
                let report = dataSource.getIntegrityReport(),
                let entity = dataSource.currentEntity else { return nil }

            let currentEntityIssues = report.issues(for: entity.id)
            guard !currentEntityIssues.isEmpty else { return nil }

            let banner = UIView()
            banner.translatesAutoresizingMaskIntoConstraints = false
            banner.backgroundColor = .systemRed.withAlphaComponent(0.1)
            banner.layer.cornerRadius = 8

            let warningIcon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
            warningIcon.translatesAutoresizingMaskIntoConstraints = false
            warningIcon.tintColor = .systemRed
            warningIcon.contentMode = .scaleAspectFit

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .systemRed
            label.text = "Found \(currentEntityIssues.count) issue\(currentEntityIssues.count == 1 ? "" : "s")"
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail

            let fixButton = UIButton(type: .system)
            fixButton.translatesAutoresizingMaskIntoConstraints = false
            fixButton.setTitle("Fix", for: .normal)
            fixButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            fixButton.tintColor = .systemRed
            fixButton.addTarget(self, action: #selector(self.fixIssuesTapped), for: .touchUpInside)

            let showButton = UIButton(type: .system)
            showButton.translatesAutoresizingMaskIntoConstraints = false
            showButton.setTitle("Show", for: .normal)
            showButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            showButton.tintColor = .systemRed
            showButton.addTarget(self, action: #selector(self.filterToIssuesTapped), for: .touchUpInside)

            banner.addSubview(warningIcon)
            banner.addSubview(label)
            banner.addSubview(fixButton)
            banner.addSubview(showButton)

            NSLayoutConstraint.activate([
                banner.heightAnchor.constraint(equalToConstant: 32),

                warningIcon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
                warningIcon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
                warningIcon.widthAnchor.constraint(equalToConstant: 16),
                warningIcon.heightAnchor.constraint(equalToConstant: 16),

                label.leadingAnchor.constraint(equalTo: warningIcon.trailingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

                showButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
                showButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

                fixButton.trailingAnchor.constraint(equalTo: showButton.leadingAnchor, constant: -12),
                fixButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

                label.trailingAnchor.constraint(lessThanOrEqualTo: fixButton.leadingAnchor, constant: -8),
            ])

            return banner
        }

        @objc private func filterToIssuesTapped() {
            self.dataSource.setIssueFilter(enabled: true)
            self.reloadData()
        }

        @objc private func fixIssuesTapped() {
            guard
                let report = dataSource.getIntegrityReport(),
                let entity = dataSource.currentEntity,
                let checker = dataSource.configuration.integrityChecker else { return }

            let currentEntityIssues = report.issues(for: entity.id)
            guard !currentEntityIssues.isEmpty else { return }

            let message = "This will attempt to fix \(currentEntityIssues.count) issue\(currentEntityIssues.count == 1 ? "" : "s").\n\nThis action cannot be undone."

            let alert = UIAlertController(
                title: "Fix Data Issues?",
                message: message,
                preferredStyle: .alert,
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Fix Issues", style: .destructive) { [weak self] _ in
                self?.performFix(issues: currentEntityIssues, checker: checker)
            })

            present(alert, animated: true)
        }

        private func performFix(issues: [PolyDataIntegrityIssue], checker: any PolyDataIntegrityChecker) {
            self.dataSource.context.showProgress?("Fixing data issues...")

            Task { [weak self] in
                guard let self else { return }
                let fixedCount = await checker.fix(issues: issues, context: self.dataSource.modelContext)

                self.dataSource.invalidateIntegrityCache()
                self.reloadData()
                self.dataSource.context.hideProgress?()
                self.dataSource.context.showAlert?(
                    "Fix Complete",
                    "Fixed \(fixedCount) issue\(fixedCount == 1 ? "" : "s").")
            }
        }
    }

    // MARK: - UITableViewDataSource

    extension iOSPolyDataExplorerRecordsViewController: UITableViewDataSource {
        func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
            self.records.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: iOSPolyDataExplorerCell.reuseIdentifier,
                for: indexPath,
            ) as! iOSPolyDataExplorerCell

            guard
                indexPath.row < self.records.count,
                let entity = dataSource.currentEntity else { return cell }

            let record = self.records[indexPath.row]
            let report = self.dataSource.getIntegrityReport()

            cell.configure(with: record, entity: entity, report: report)

            return cell
        }
    }

    // MARK: - UITableViewDelegate

    extension iOSPolyDataExplorerRecordsViewController: UITableViewDelegate {
        func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
            guard indexPath.row < self.records.count else { return }
            self.onSelectRecord?(self.records[indexPath.row])
        }

        func tableView(
            _: UITableView,
            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
        ) -> UISwipeActionsConfiguration? {
            let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
                self?.deleteRecord(at: indexPath)
                completion(true)
            }

            return UISwipeActionsConfiguration(actions: [deleteAction])
        }

        private func deleteRecord(at indexPath: IndexPath) {
            guard indexPath.row < self.records.count else { return }

            let alert = UIAlertController(
                title: "Delete Record?",
                message: "This action cannot be undone.",
                preferredStyle: .alert,
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                guard let self else { return }
                let record = self.records[indexPath.row]
                Task {
                    await self.dataSource.deleteRecord(record)
                    self.reloadData()
                }
            })

            present(alert, animated: true)
        }
    }

    // MARK: - UISearchResultsUpdating

    extension iOSPolyDataExplorerRecordsViewController: UISearchResultsUpdating {
        func updateSearchResults(for searchController: UISearchController) {
            self.dataSource.setSearchText(searchController.searchBar.text ?? "")
            self.reloadData()
        }
    }

#endif // os(iOS)
