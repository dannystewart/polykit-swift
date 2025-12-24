#if os(iOS)

    import SwiftData
    import UIKit

    // MARK: - iOSPolyDataExplorerViewController

    /// Main view controller for the Data Explorer on iOS.
    ///
    /// Displays a table of records for the selected entity type with search,
    /// sort, and filter capabilities.
    @MainActor
    public final class iOSPolyDataExplorerViewController: UIViewController {
        // MARK: Properties

        private let dataSource: PolyDataExplorerDataSource
        private var records: [AnyObject] = []

        // UI Components
        private var segmentedControl: UISegmentedControl!
        private var tableView: UITableView!
        private var searchController: UISearchController!
        private var statsLabel: UILabel!
        private var filterBanner: UIView?
        private var warningBanner: UIView?
        private var tableViewTopConstraint: NSLayoutConstraint?

        // Progress overlay
        private var progressOverlay: UIView?
        private var progressLabel: UILabel?

        // MARK: Initialization

        /// Creates a new Data Explorer view controller.
        ///
        /// - Parameters:
        ///   - configuration: The explorer configuration.
        ///   - modelContext: The SwiftData model context.
        public init(configuration: PolyDataExplorerConfiguration, modelContext: ModelContext) {
            self.dataSource = PolyDataExplorerDataSource(
                configuration: configuration,
                modelContext: modelContext
            )
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Lifecycle

        override public func viewDidLoad() {
            super.viewDidLoad()
            setupContextCallbacks()
            setupUI()
            setupNavigationBar()
            setupSearchController()
            reloadData()
        }

        // MARK: Setup

        private func setupContextCallbacks() {
            let context = dataSource.context

            context.reloadData = { [weak self] in
                self?.reloadData()
            }

            context.showAlert = { [weak self] title, message in
                self?.showAlert(title: title, message: message)
            }

            context.showProgress = { [weak self] message in
                self?.showProgressOverlay(message: message)
            }

            context.hideProgress = { [weak self] in
                self?.hideProgressOverlay()
            }

            context.updateProgress = { [weak self] message in
                self?.updateProgressOverlay(message: message)
            }

            context.switchToEntity = { [weak self] index in
                self?.switchToEntity(at: index)
            }

            context.applyFilter = { [weak self] filter in
                self?.dataSource.setFilter(filter)
                self?.reloadData()
                self?.updateFilterBanner()
            }

            context.clearFilter = { [weak self] in
                self?.dataSource.clearFilter()
                self?.reloadData()
                self?.updateFilterBanner()
            }

            context.dismiss = { [weak self] in
                self?.dismiss(animated: true)
            }
        }

        private func setupUI() {
            view.backgroundColor = .systemGroupedBackground

            // Stats label at top
            statsLabel = UILabel()
            statsLabel.translatesAutoresizingMaskIntoConstraints = false
            statsLabel.font = .systemFont(ofSize: 12)
            statsLabel.textColor = .secondaryLabel
            statsLabel.textAlignment = .center
            view.addSubview(statsLabel)

            // Segmented control for entity selection
            let entityNames = dataSource.configuration.entities.map(\.displayName)
            segmentedControl = UISegmentedControl(items: entityNames)
            segmentedControl.translatesAutoresizingMaskIntoConstraints = false
            segmentedControl.selectedSegmentIndex = dataSource.currentEntityIndex
            segmentedControl.addTarget(self, action: #selector(entityChanged(_:)), for: .valueChanged)
            view.addSubview(segmentedControl)

            // Table view
            tableView = UITableView(frame: .zero, style: .plain)
            tableView.translatesAutoresizingMaskIntoConstraints = false
            tableView.delegate = self
            tableView.dataSource = self
            tableView.register(
                iOSPolyDataExplorerCell.self,
                forCellReuseIdentifier: iOSPolyDataExplorerCell.reuseIdentifier
            )
            tableView.rowHeight = UITableView.automaticDimension
            tableView.estimatedRowHeight = 80
            view.addSubview(tableView)

            tableViewTopConstraint = tableView.topAnchor.constraint(
                equalTo: segmentedControl.bottomAnchor,
                constant: 12
            )

            NSLayoutConstraint.activate([
                statsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                statsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                statsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

                segmentedControl.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 12),
                segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

                tableViewTopConstraint!,
                tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        private func setupNavigationBar() {
            title = dataSource.configuration.title
            navigationController?.navigationBar.prefersLargeTitles = false

            let doneButton = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(handleDone)
            )
            navigationItem.rightBarButtonItem = doneButton

            // Sort menu
            let sortButton = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down"),
                menu: createSortMenu()
            )

            // Tools menu (if there are toolbar sections)
            var leftItems = [UIBarButtonItem]()

            if !dataSource.configuration.toolbarSections.isEmpty {
                let toolsButton = UIBarButtonItem(
                    image: UIImage(systemName: "wrench.and.screwdriver"),
                    menu: createToolsMenu()
                )
                leftItems.append(toolsButton)
            }

            leftItems.append(sortButton)
            navigationItem.leftBarButtonItems = leftItems
        }

        private func setupSearchController() {
            searchController = UISearchController(searchResultsController: nil)
            searchController.searchResultsUpdater = self
            searchController.obscuresBackgroundDuringPresentation = false
            searchController.searchBar.placeholder = "Search..."
            navigationItem.searchController = searchController
            definesPresentationContext = true
        }

        // MARK: Actions

        @objc private func handleDone() {
            dismiss(animated: true)
        }

        @objc private func entityChanged(_ sender: UISegmentedControl) {
            dataSource.selectEntity(at: sender.selectedSegmentIndex)
            reloadData()
            updateSortMenu()
            updateFilterBanner()
        }

        @objc private func clearFilter() {
            dataSource.clearFilter()
            reloadData()
            updateFilterBanner()
        }

        private func switchToEntity(at index: Int) {
            segmentedControl.selectedSegmentIndex = index
            dataSource.selectEntity(at: index)
            reloadData()
            updateSortMenu()
            updateFilterBanner()
        }

        // MARK: Menus

        private func createSortMenu() -> UIMenu {
            guard let entity = dataSource.currentEntity else {
                return UIMenu(title: "Sort By", children: [])
            }

            let currentFieldID = dataSource.currentSortFieldID
            let ascending = dataSource.currentSortAscending

            var actions = [UIAction]()

            for i in 0 ..< entity.sortFieldCount {
                let fieldID = entity.sortFieldID(i)
                let displayName = entity.sortFieldDisplayName(i)
                let isSelected = fieldID == currentFieldID

                let action = UIAction(
                    title: displayName,
                    image: isSelected ? UIImage(systemName: ascending ? "chevron.up" : "chevron.down") : nil,
                    state: isSelected ? .on : .off
                ) { [weak self] _ in
                    self?.dataSource.toggleSort(fieldID: fieldID)
                    self?.reloadData()
                    self?.updateSortMenu()
                }

                actions.append(action)
            }

            return UIMenu(title: "Sort By", children: actions)
        }

        private func createToolsMenu() -> UIMenu {
            var menuChildren = [UIMenuElement]()

            for section in dataSource.configuration.toolbarSections {
                var sectionActions = [UIAction]()

                for action in section.actions {
                    let uiAction = UIAction(
                        title: action.title,
                        image: UIImage(systemName: action.iconName),
                        attributes: action.isDestructive ? .destructive : []
                    ) { [weak self] _ in
                        guard let self else { return }
                        Task {
                            await action.action(self.dataSource.context)
                        }
                    }
                    sectionActions.append(uiAction)
                }

                let sectionMenu = UIMenu(title: "", options: .displayInline, children: sectionActions)
                menuChildren.append(sectionMenu)
            }

            return UIMenu(title: "Tools", children: menuChildren)
        }

        private func updateSortMenu() {
            // Find the sort button and update its menu
            if let leftItems = navigationItem.leftBarButtonItems {
                for item in leftItems {
                    if item.image == UIImage(systemName: "arrow.up.arrow.down") {
                        item.menu = createSortMenu()
                        break
                    }
                }
            }
        }

        // MARK: Data Loading

        private func reloadData() {
            // Refresh integrity analysis
            dataSource.invalidateIntegrityCache()
            _ = dataSource.getIntegrityReport()

            // Fetch records
            records = dataSource.fetchCurrentRecords()

            tableView.reloadData()
            updateStats()
            updateFilterBanner()
            updateWarningBanner()
        }

        private func updateStats() {
            guard dataSource.configuration.showStats else {
                statsLabel.isHidden = true
                return
            }

            statsLabel.isHidden = false
            let stats = dataSource.fetchStats()
            statsLabel.text = stats.formattedString
        }

        // MARK: Filter Banner

        private func updateFilterBanner() {
            // Remove existing banner
            filterBanner?.removeFromSuperview()
            filterBanner = nil

            let showIssuesFilter = dataSource.showOnlyIssues
            let regularFilter = dataSource.currentFilter

            guard showIssuesFilter || regularFilter != nil else { return }

            // Create filter banner
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
            clearButton.addTarget(self, action: #selector(clearFilter), for: .touchUpInside)

            banner.addSubview(label)
            banner.addSubview(clearButton)
            view.addSubview(banner)

            // Update table view constraint
            tableViewTopConstraint?.isActive = false
            tableViewTopConstraint = tableView.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8)
            tableViewTopConstraint?.isActive = true

            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
                banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                banner.heightAnchor.constraint(equalToConstant: 32),

                label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
                label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

                clearButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
                clearButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            ])

            filterBanner = banner
        }

        // MARK: Warning Banner

        private func updateWarningBanner() {
            guard let report = dataSource.getIntegrityReport(),
                  let entity = dataSource.currentEntity else {
                hideWarningBanner()
                return
            }

            let currentEntityIssues = report.issues(for: entity.id)

            // Update segmented control with warning indicators
            updateSegmentedControlWarnings(report: report)

            if currentEntityIssues.isEmpty {
                hideWarningBanner()
            } else {
                showWarningBanner(for: currentEntityIssues)
            }
        }

        private func showWarningBanner(for issues: [PolyDataIntegrityIssue]) {
            warningBanner?.removeFromSuperview()

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
            label.text = "Found \(issues.count) issue\(issues.count == 1 ? "" : "s")"
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail

            let fixButton = UIButton(type: .system)
            fixButton.translatesAutoresizingMaskIntoConstraints = false
            fixButton.setTitle("Fix", for: .normal)
            fixButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            fixButton.tintColor = .systemRed
            fixButton.addTarget(self, action: #selector(fixIssuesTapped), for: .touchUpInside)

            let showButton = UIButton(type: .system)
            showButton.translatesAutoresizingMaskIntoConstraints = false
            showButton.setTitle("Show", for: .normal)
            showButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            showButton.tintColor = .systemRed
            showButton.addTarget(self, action: #selector(filterToIssuesTapped), for: .touchUpInside)

            banner.addSubview(warningIcon)
            banner.addSubview(label)
            banner.addSubview(fixButton)
            banner.addSubview(showButton)
            view.addSubview(banner)

            tableViewTopConstraint?.isActive = false
            tableViewTopConstraint = tableView.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8)
            tableViewTopConstraint?.isActive = true

            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
                banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
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

            warningBanner = banner
        }

        private func hideWarningBanner() {
            guard warningBanner != nil else { return }

            warningBanner?.removeFromSuperview()
            warningBanner = nil

            tableViewTopConstraint?.isActive = false
            tableViewTopConstraint = tableView.topAnchor.constraint(
                equalTo: segmentedControl.bottomAnchor,
                constant: 12
            )
            tableViewTopConstraint?.isActive = true
        }

        private func updateSegmentedControlWarnings(report: PolyDataIntegrityReport) {
            let issuesByEntity = report.issueCountsByEntity

            for (index, entity) in dataSource.configuration.entities.enumerated() {
                let issueCount = issuesByEntity[entity.id] ?? 0
                if issueCount > 0, entity.id != dataSource.currentEntity?.id {
                    segmentedControl.setTitle("⚠️ \(entity.displayName)", forSegmentAt: index)
                } else {
                    segmentedControl.setTitle(entity.displayName, forSegmentAt: index)
                }
            }
        }

        @objc private func filterToIssuesTapped() {
            dataSource.setIssueFilter(enabled: true)
            reloadData()
            updateFilterBanner()
        }

        @objc private func fixIssuesTapped() {
            guard let report = dataSource.getIntegrityReport(),
                  let entity = dataSource.currentEntity,
                  let checker = dataSource.configuration.integrityChecker else { return }

            let currentEntityIssues = report.issues(for: entity.id)
            guard !currentEntityIssues.isEmpty else { return }

            let message = "This will attempt to fix \(currentEntityIssues.count) issue\(currentEntityIssues.count == 1 ? "" : "s").\n\nThis action cannot be undone."

            let alert = UIAlertController(
                title: "Fix Data Issues?",
                message: message,
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Fix Issues", style: .destructive) { [weak self] _ in
                self?.performFix(issues: currentEntityIssues, checker: checker)
            })

            present(alert, animated: true)
        }

        private func performFix(issues: [PolyDataIntegrityIssue], checker: any PolyDataIntegrityChecker) {
            showProgressOverlay(message: "Fixing data issues...")

            Task {
                let fixedCount = await checker.fix(issues: issues, context: dataSource.modelContext)

                dataSource.invalidateIntegrityCache()
                reloadData()
                hideProgressOverlay()
                showAlert(title: "Fix Complete", message: "Fixed \(fixedCount) issue\(fixedCount == 1 ? "" : "s").")
            }
        }

        // MARK: Progress Overlay

        private func showProgressOverlay(message: String) {
            progressOverlay?.removeFromSuperview()

            let overlay = UIView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)

            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .systemBackground
            container.layer.cornerRadius = 12

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = message
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .label
            label.textAlignment = .center
            label.numberOfLines = 0

            container.addSubview(spinner)
            container.addSubview(label)
            overlay.addSubview(container)
            view.addSubview(overlay)

            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                container.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                container.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                container.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

                spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
                spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),

                label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            ])

            progressOverlay = overlay
            progressLabel = label
        }

        private func updateProgressOverlay(message: String) {
            progressLabel?.text = message
        }

        private func hideProgressOverlay() {
            progressOverlay?.removeFromSuperview()
            progressOverlay = nil
            progressLabel = nil
        }

        // MARK: Alerts

        private func showAlert(title: String, message: String) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }

        // MARK: Detail View

        private func showDetail(for indexPath: IndexPath) {
            guard indexPath.row < records.count,
                  let entity = dataSource.currentEntity else { return }

            let record = records[indexPath.row]
            let detail = iOSPolyDataExplorerDetailController(
                record: record,
                entity: entity,
                dataSource: dataSource
            )
            navigationController?.pushViewController(detail, animated: true)
        }
    }

    // MARK: - UITableViewDataSource

    extension iOSPolyDataExplorerViewController: UITableViewDataSource {
        public func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
            records.count
        }

        public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: iOSPolyDataExplorerCell.reuseIdentifier,
                for: indexPath
            ) as! iOSPolyDataExplorerCell

            guard indexPath.row < records.count,
                  let entity = dataSource.currentEntity else { return cell }

            let record = records[indexPath.row]
            let report = dataSource.getIntegrityReport()

            cell.configure(with: record, entity: entity, report: report)

            return cell
        }
    }

    // MARK: - UITableViewDelegate

    extension iOSPolyDataExplorerViewController: UITableViewDelegate {
        public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            showDetail(for: indexPath)
        }

        public func tableView(
            _: UITableView,
            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
        ) -> UISwipeActionsConfiguration? {
            let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
                self?.deleteRecord(at: indexPath)
                completion(true)
            }

            return UISwipeActionsConfiguration(actions: [deleteAction])
        }

        private func deleteRecord(at indexPath: IndexPath) {
            guard indexPath.row < records.count else { return }

            let alert = UIAlertController(
                title: "Delete Record?",
                message: "This action cannot be undone.",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                guard let self else { return }
                let record = records[indexPath.row]
                Task {
                    await self.dataSource.deleteRecord(record)
                    self.reloadData()
                }
            })

            present(alert, animated: true)
        }
    }

    // MARK: - UISearchResultsUpdating

    extension iOSPolyDataExplorerViewController: UISearchResultsUpdating {
        public func updateSearchResults(for searchController: UISearchController) {
            dataSource.setSearchText(searchController.searchBar.text ?? "")
            reloadData()
        }
    }

#endif // os(iOS)
