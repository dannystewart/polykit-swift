#if os(macOS)

    import AppKit
    import SwiftData

    // MARK: - macOSPolyDataExplorerSplitViewController

    /// Split view controller containing the table and detail panel.
    @MainActor
    public final class macOSPolyDataExplorerSplitViewController: NSSplitViewController {
        // MARK: Properties

        private let dataSource: PolyDataExplorerDataSource
        private var tableViewController: macOSPolyDataExplorerViewController!
        private var detailPanel: macOSPolyDataExplorerDetailPanel!

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

        override public func viewDidLoad() {
            super.viewDidLoad()
            setupSplitView()
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
        }

        // MARK: Public Methods

        public func refresh() {
            tableViewController.reloadData()
            detailPanel.showEmpty()
        }

        public func switchToEntity(at index: Int) {
            dataSource.selectEntity(at: index)
            tableViewController.reloadData()
            detailPanel.showEmpty()
        }

        public var currentEntityIndex: Int {
            dataSource.currentEntityIndex
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
