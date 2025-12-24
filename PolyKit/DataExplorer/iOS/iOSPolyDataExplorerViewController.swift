#if os(iOS)

    import SwiftData
    import UIKit

    // MARK: - iOSPolyDataExplorerViewController

    /// Main view controller for the Data Explorer on iOS.
    ///
    /// Displays a split view (records list + inspector) on iPad and collapses
    /// down to list → detail navigation on iPhone.
    @MainActor
    public final class iOSPolyDataExplorerViewController: UISplitViewController {
        // MARK: Properties

        private let dataSource: PolyDataExplorerDataSource

        private let recordsViewController: iOSPolyDataExplorerRecordsViewController
        private let detailViewController: iOSPolyDataExplorerDetailController

        // Progress overlay (covers the whole split view).
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

            self.recordsViewController = iOSPolyDataExplorerRecordsViewController(dataSource: dataSource)
            self.detailViewController = iOSPolyDataExplorerDetailController(dataSource: dataSource)

            super.init(style: .doubleColumn)

            preferredSplitBehavior = .tile
            preferredDisplayMode = .oneBesideSecondary

            setViewController(recordsViewController, for: .primary)
            setViewController(recordsViewController, for: .compact)
            setViewController(detailViewController, for: .secondary)

            setupContextCallbacks()

            recordsViewController.onSelectRecord = { [weak self] record in
                self?.showInspector(for: record)
            }

            recordsViewController.onEntitySelected = { [weak self] index in
                self?.switchToEntity(at: index)
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Setup

        private func setupContextCallbacks() {
            let context = dataSource.context

            context.reloadData = { [weak self] in
                self?.recordsViewController.reloadData()
                self?.detailViewController.tableView.reloadData()
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
                self?.recordsViewController.reloadData()
                self?.clearInspector()
            }

            context.clearFilter = { [weak self] in
                self?.dataSource.clearFilter()
                self?.recordsViewController.reloadData()
                self?.clearInspector()
            }

            context.dismiss = { [weak self] in
                self?.dismiss(animated: true)
            }
        }

        // MARK: Selection / Navigation

        private func showInspector(for record: AnyObject) {
            guard let entity = dataSource.currentEntity else { return }

            detailViewController.setRecord(record, entity: entity)

            // On compact size classes, this will navigate to the detail column.
            show(.secondary)
        }

        private func clearInspector() {
            detailViewController.setRecord(nil, entity: nil)
            if isCollapsed {
                show(.primary)
            }
        }

        private func switchToEntity(at index: Int) {
            recordsViewController.setSelectedEntityIndex(index)
            clearInspector()
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
    }

#endif // os(iOS)
