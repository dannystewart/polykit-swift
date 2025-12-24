//
//  iOSPolyDataExplorerViewController.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

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
                modelContext: modelContext,
            )

            self.recordsViewController = iOSPolyDataExplorerRecordsViewController(dataSource: self.dataSource)
            self.detailViewController = iOSPolyDataExplorerDetailController(dataSource: self.dataSource)

            super.init(style: .doubleColumn)

            preferredSplitBehavior = .tile
            preferredDisplayMode = .oneBesideSecondary

            // Embed columns in navigation controllers so:
            // - Compact-width (iPhone / narrow iPad windows) can push list → detail correctly
            // - Nav bar items (Done, entity picker, search, etc.) appear as intended
            let primaryNav = UINavigationController(rootViewController: self.recordsViewController)
            primaryNav.navigationBar.prefersLargeTitles = false
            primaryNav.view.backgroundColor = .clear

            let secondaryNav = UINavigationController(rootViewController: self.detailViewController)
            secondaryNav.navigationBar.prefersLargeTitles = false
            secondaryNav.view.backgroundColor = .clear

            setViewController(primaryNav, for: .primary)
            setViewController(secondaryNav, for: .secondary)

            self.setupContextCallbacks()

            self.recordsViewController.onSelectRecord = { [weak self] record in
                self?.showInspector(for: record)
            }

            self.recordsViewController.onEntitySelected = { [weak self] index in
                self?.switchToEntity(at: index)
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Setup

        private func setupContextCallbacks() {
            let context = self.dataSource.context

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

            self.detailViewController.setRecord(record, entity: entity)

            // On compact size classes, this will navigate to the detail column.
            show(.secondary)
        }

        private func clearInspector() {
            self.detailViewController.setRecord(nil, entity: nil)
            if isCollapsed {
                show(.primary)
            }
        }

        private func switchToEntity(at index: Int) {
            self.recordsViewController.setSelectedEntityIndex(index)
            self.clearInspector()
        }

        // MARK: Progress Overlay

        private func showProgressOverlay(message: String) {
            self.progressOverlay?.removeFromSuperview()

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

            self.progressOverlay = overlay
            self.progressLabel = label
        }

        private func updateProgressOverlay(message: String) {
            self.progressLabel?.text = message
        }

        private func hideProgressOverlay() {
            self.progressOverlay?.removeFromSuperview()
            self.progressOverlay = nil
            self.progressLabel = nil
        }

        // MARK: Alerts

        private func showAlert(title: String, message: String) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

#endif // os(iOS)
