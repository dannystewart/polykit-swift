#if os(macOS)

    import AppKit
    import SwiftData

    // MARK: - macOSPolyDataExplorerWindowController

    /// Window controller for the Data Explorer on macOS.
    @MainActor
    public final class macOSPolyDataExplorerWindowController: NSWindowController {
        // MARK: Properties

        private let configuration: PolyDataExplorerConfiguration
        private let dataSource: PolyDataExplorerDataSource
        private var splitViewController: macOSPolyDataExplorerSplitViewController?

        private var entitySegmentedControl: NSSegmentedControl?
        private var statsLabel: NSTextField?

        // MARK: Initialization

        /// Creates a new Data Explorer window.
        ///
        /// - Parameters:
        ///   - configuration: The explorer configuration.
        ///   - modelContext: The SwiftData model context.
        public init(configuration: PolyDataExplorerConfiguration, modelContext: ModelContext) {
            self.configuration = configuration
            self.dataSource = PolyDataExplorerDataSource(
                configuration: configuration,
                modelContext: modelContext
            )

            let window = Self.createWindow(title: configuration.title)
            super.init(window: window)

            setupContextCallbacks()
            setupToolbar()
            setupContent()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Window Creation

        private static func createWindow(title: String) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.center()
            window.setFrameAutosaveName("PolyDataExplorer")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 800, height: 400)

            return window
        }

        // MARK: Setup

        private func setupContextCallbacks() {
            let context = dataSource.context

            context.reloadData = { [weak self] in
                self?.splitViewController?.refresh()
                self?.updateStats()
            }

            context.showAlert = { [weak self] title, message in
                self?.showAlert(title: title, message: message)
            }

            context.showProgress = { [weak self] message in
                self?.showProgress(message: message)
            }

            context.hideProgress = { [weak self] in
                self?.hideProgress()
            }

            context.switchToEntity = { [weak self] index in
                self?.switchToEntity(at: index)
            }

            context.applyFilter = { [weak self] filter in
                self?.dataSource.setFilter(filter)
                self?.splitViewController?.refresh()
            }

            context.clearFilter = { [weak self] in
                self?.dataSource.clearFilter()
                self?.splitViewController?.refresh()
            }
        }

        private func setupToolbar() {
            let toolbar = NSToolbar(identifier: "PolyDataExplorerToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = false
            window?.toolbar = toolbar
        }

        private func setupContent() {
            splitViewController = macOSPolyDataExplorerSplitViewController(dataSource: dataSource)
            window?.contentViewController = splitViewController
            splitViewController?.refresh()
            updateStats()
        }

        // MARK: Public Methods

        /// Shows the window.
        public func showWindow() {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        /// Refreshes the data display.
        public func refresh() {
            splitViewController?.refresh()
            updateStats()
        }

        // MARK: Private Methods

        private func switchToEntity(at index: Int) {
            dataSource.selectEntity(at: index)
            entitySegmentedControl?.selectedSegment = index
            splitViewController?.refresh()
            updateStats()
        }

        @objc private func entitySegmentChanged(_ sender: NSSegmentedControl) {
            switchToEntity(at: sender.selectedSegment)
        }

        private func updateStats() {
            guard configuration.showStats else { return }
            let stats = dataSource.fetchStats()
            statsLabel?.stringValue = stats.formattedString
        }

        private func showAlert(title: String, message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")

            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }

        private var progressIndicator: NSProgressIndicator?
        private var progressLabel: NSTextField?

        private func showProgress(message: String) {
            guard let window, let contentView = window.contentView else { return }

            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.identifier = NSUserInterfaceItemIdentifier("progressOverlay")

            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            container.layer?.cornerRadius = 12
            container.translatesAutoresizingMaskIntoConstraints = false

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)

            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            progressLabel = label

            container.addSubview(spinner)
            container.addSubview(label)
            overlay.addSubview(container)
            contentView.addSubview(overlay)

            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

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
        }

        private func hideProgress() {
            guard let contentView = window?.contentView else { return }
            for subview in contentView.subviews {
                if subview.identifier == NSUserInterfaceItemIdentifier("progressOverlay") {
                    subview.removeFromSuperview()
                    break
                }
            }
            progressLabel = nil
        }
    }

    // MARK: - NSToolbarDelegate

    extension macOSPolyDataExplorerWindowController: NSToolbarDelegate {
        public func toolbar(
            _: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar _: Bool
        ) -> NSToolbarItem? {
            switch itemIdentifier.rawValue {
            case "entitySelector":
                return createEntitySelectorItem()
            case "stats":
                return createStatsItem()
            case "tools":
                return createToolsItem()
            case "flexibleSpace":
                return NSToolbarItem(itemIdentifier: .flexibleSpace)
            default:
                return nil
            }
        }

        public func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            var identifiers: [NSToolbarItem.Identifier] = [
                NSToolbarItem.Identifier("entitySelector"),
            ]

            if configuration.showStats {
                identifiers.append(NSToolbarItem.Identifier("stats"))
            }

            identifiers.append(.flexibleSpace)

            if !configuration.toolbarSections.isEmpty {
                identifiers.append(NSToolbarItem.Identifier("tools"))
            }

            return identifiers
        }

        public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        private func createEntitySelectorItem() -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("entitySelector"))

            let segmented = NSSegmentedControl()
            segmented.segmentStyle = .texturedSquare
            segmented.trackingMode = .selectOne
            segmented.segmentCount = configuration.entities.count

            for (index, entity) in configuration.entities.enumerated() {
                segmented.setLabel(entity.displayName, forSegment: index)
                if let image = NSImage(systemSymbolName: entity.iconName, accessibilityDescription: entity.displayName) {
                    segmented.setImage(image, forSegment: index)
                }
            }

            segmented.selectedSegment = configuration.defaultEntityIndex
            segmented.target = self
            segmented.action = #selector(entitySegmentChanged(_:))

            entitySegmentedControl = segmented
            item.view = segmented

            return item
        }

        private func createStatsItem() -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("stats"))

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            statsLabel = label

            item.view = label

            return item
        }

        private func createToolsItem() -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("tools"))
            item.label = "Tools"
            item.paletteLabel = "Tools"
            item.toolTip = "Data management tools"

            let button = NSButton()
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Tools")

            // Build menu
            let menu = NSMenu()

            for section in configuration.toolbarSections {
                if !menu.items.isEmpty {
                    menu.addItem(.separator())
                }

                for action in section.actions {
                    let menuItem = NSMenuItem(title: action.title, action: #selector(toolbarActionTriggered(_:)), keyEquivalent: "")
                    menuItem.target = self
                    menuItem.representedObject = action.id
                    if let image = NSImage(systemSymbolName: action.iconName, accessibilityDescription: action.title) {
                        menuItem.image = image
                    }
                    menu.addItem(menuItem)
                }
            }

            button.menu = menu
            button.action = #selector(showToolsMenu(_:))
            button.target = self

            item.view = button

            return item
        }

        @objc private func showToolsMenu(_ sender: NSButton) {
            guard let menu = sender.menu else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }

        @objc private func toolbarActionTriggered(_ sender: NSMenuItem) {
            guard let actionID = sender.representedObject as? String else { return }

            // Find the action
            for section in configuration.toolbarSections {
                for action in section.actions where action.id == actionID {
                    Task {
                        await action.action(dataSource.context)
                    }
                    return
                }
            }
        }
    }

#endif // os(macOS)
