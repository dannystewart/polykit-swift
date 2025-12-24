//
//  macOSPolyDataExplorerSplitViewController.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(macOS)

    import AppKit
    import SwiftData

    // MARK: - macOSPolyDataExplorerSplitViewController

    /// Split view controller containing the table and detail panel.
    @MainActor
    public final class macOSPolyDataExplorerSplitViewController: NSSplitViewController {
        private let dataSource: PolyDataExplorerDataSource
        private var tableViewController: macOSPolyDataExplorerViewController!
        private var detailPanel: macOSPolyDataExplorerDetailPanel!

        // Stats bar (matches Prism's older Data Explorer UX).
        private var statsLabel: NSTextField?
        private var filterLabel: NSTextField?
        private var clearFilterButton: NSButton?
        private var splitViewTopConstraint: NSLayoutConstraint?

        public var currentEntityIndex: Int {
            dataSource.currentEntityIndex
        }

        // MARK: Initialization

        public init(dataSource: PolyDataExplorerDataSource) {
            self.dataSource = dataSource
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public func viewDidLoad() {
            super.viewDidLoad()
            setupSplitView()
            setupStatsBarIfNeeded()
            refresh()
        }

        // MARK: Public Methods

        public func refresh() {
            tableViewController.reloadData()
            detailPanel.showEmpty()
            updateStats()
            updateFilterIndicator()
        }

        public func switchToEntity(at index: Int) {
            dataSource.selectEntity(at: index)
            tableViewController.reloadData()
            detailPanel.showEmpty()
            updateStats()
            updateFilterIndicator()
        }

        public func toggleDetailPanel() {
            guard splitViewItems.count > 1 else { return }
            let detailItem = splitViewItems[1]

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                detailItem.animator().isCollapsed.toggle()
            }
        }

        // MARK: Setup

        private func setupSplitView() {
            // Table view (main content)
            tableViewController = macOSPolyDataExplorerViewController(dataSource: dataSource)
            tableViewController.delegate = self

            let tableItem = NSSplitViewItem(viewController: tableViewController)
            tableItem.minimumThickness = 400
            tableItem.canCollapse = false
            addSplitViewItem(tableItem)

            // Detail panel (inspector)
            detailPanel = macOSPolyDataExplorerDetailPanel(dataSource: dataSource)

            let detailItem = NSSplitViewItem(viewController: detailPanel)
            detailItem.minimumThickness = 250
            detailItem.maximumThickness = 350
            detailItem.canCollapse = true
            detailItem.isCollapsed = false
            addSplitViewItem(detailItem)

            splitView.dividerStyle = .thin
            splitView.isVertical = true
            splitView.autosaveName = "PolyDataExplorerSplit"
        }

        private func setupStatsBarIfNeeded() {
            guard dataSource.configuration.showStats else { return }

            let statsBar = NSView()
            statsBar.translatesAutoresizingMaskIntoConstraints = false
            statsBar.wantsLayer = true
            statsBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

            let statsLabel = NSTextField(labelWithString: "Loading…")
            statsLabel.font = .systemFont(ofSize: 11)
            statsLabel.textColor = .secondaryLabelColor
            statsLabel.translatesAutoresizingMaskIntoConstraints = false

            let filterLabel = NSTextField(labelWithString: "")
            filterLabel.font = .systemFont(ofSize: 11, weight: .medium)
            filterLabel.textColor = .systemBlue
            filterLabel.translatesAutoresizingMaskIntoConstraints = false
            filterLabel.isHidden = true

            let clearFilterButton = NSButton(title: "Clear", target: self, action: #selector(clearFilter))
            clearFilterButton.bezelStyle = .inline
            clearFilterButton.font = .systemFont(ofSize: 10)
            clearFilterButton.translatesAutoresizingMaskIntoConstraints = false
            clearFilterButton.isHidden = true

            statsBar.addSubview(statsLabel)
            statsBar.addSubview(filterLabel)
            statsBar.addSubview(clearFilterButton)

            view.addSubview(statsBar)

            // Position the split view below the stats bar.
            splitView.translatesAutoresizingMaskIntoConstraints = false
            splitViewTopConstraint = splitView.topAnchor.constraint(equalTo: statsBar.bottomAnchor)

            NSLayoutConstraint.activate([
                statsBar.topAnchor.constraint(equalTo: view.topAnchor),
                statsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                statsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                statsBar.heightAnchor.constraint(equalToConstant: 28),

                statsLabel.leadingAnchor.constraint(equalTo: statsBar.leadingAnchor, constant: 12),
                statsLabel.centerYAnchor.constraint(equalTo: statsBar.centerYAnchor),

                filterLabel.leadingAnchor.constraint(equalTo: statsLabel.trailingAnchor, constant: 16),
                filterLabel.centerYAnchor.constraint(equalTo: statsBar.centerYAnchor),

                clearFilterButton.leadingAnchor.constraint(equalTo: filterLabel.trailingAnchor, constant: 8),
                clearFilterButton.centerYAnchor.constraint(equalTo: statsBar.centerYAnchor),

                splitViewTopConstraint!,
                splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

            self.statsLabel = statsLabel
            self.filterLabel = filterLabel
            self.clearFilterButton = clearFilterButton
        }

        // MARK: - Stats / Filter UI

        private func updateStats() {
            guard dataSource.configuration.showStats else { return }
            guard let statsLabel else { return }

            let stats = dataSource.fetchStats()
            let parts = dataSource.configuration.entities.compactMap { entity -> String? in
                guard let count = stats.counts[entity.id] else { return nil }
                return "\(entity.displayName): \(count)"
            }
            statsLabel.stringValue = parts.joined(separator: "  •  ")
        }

        private func updateFilterIndicator() {
            guard dataSource.configuration.showStats else { return }
            guard let filterLabel, let clearFilterButton else { return }

            if dataSource.showOnlyIssues {
                filterLabel.stringValue = "Showing only records with issues"
                filterLabel.textColor = .systemRed
                filterLabel.isHidden = false
                clearFilterButton.isHidden = false
            } else if let filter = dataSource.currentFilter {
                filterLabel.stringValue = "Filter: \(filter.displayText)"
                filterLabel.textColor = .systemBlue
                filterLabel.isHidden = false
                clearFilterButton.isHidden = false
            } else {
                filterLabel.isHidden = true
                clearFilterButton.isHidden = true
            }
        }

        @objc private func clearFilter() {
            dataSource.clearFilter()
            tableViewController.reloadData()
            detailPanel.showEmpty()
            updateFilterIndicator()
        }
    }

    // MARK: - macOSPolyDataExplorerViewControllerDelegate

    extension macOSPolyDataExplorerSplitViewController: macOSPolyDataExplorerViewControllerDelegate {
        public func tableViewController(_: macOSPolyDataExplorerViewController, didSelectRecord record: AnyObject?) {
            detailPanel.showRecord(record, entity: dataSource.currentEntity)
        }

        public func tableViewController(_: macOSPolyDataExplorerViewController, didDeleteRecords _: Int) {
            detailPanel.showEmpty()
        }
    }

#endif // os(macOS)
