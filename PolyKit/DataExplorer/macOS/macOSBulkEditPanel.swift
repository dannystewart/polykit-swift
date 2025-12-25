//
//  macOSBulkEditPanel.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(macOS)

    import AppKit

    // MARK: - macOSBulkEditPanel

    /// Panel for configuring and previewing bulk edit operations on macOS.
    @MainActor
    public final class macOSBulkEditPanel: NSViewController {
        private let dataSource: PolyDataExplorerDataSource

        private var entityPopup: NSPopUpButton!
        private var targetFieldPopup: NSPopUpButton!
        private var newValueField: NSTextField!
        private var whereFieldPopup: NSPopUpButton!
        private var whereValueField: NSTextField!
        private var incrementVersionCheckbox: NSButton!
        private var previewButton: NSButton!
        private var errorLabel: NSTextField!

        private var currentEntity: AnyPolyDataEntity?
        private var editableFields: [PolyDataField] = []
        private var allFields: [PolyDataField] = []

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
            self.setupUI()
            self.populateEntityPopup()
        }

        // MARK: Setup

        private func setupUI() {
            view.wantsLayer = true

            // Container stack
            let stack = NSStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 16
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            view.addSubview(stack)

            // Title
            let titleLabel = NSTextField(labelWithString: "Bulk Edit")
            titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            stack.addArrangedSubview(titleLabel)

            // Description
            let descLabel = NSTextField(labelWithString: "Set a field to a new value for all records matching a condition.")
            descLabel.font = .systemFont(ofSize: 11)
            descLabel.textColor = .secondaryLabelColor
            descLabel.maximumNumberOfLines = 2
            descLabel.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(descLabel)
            descLabel.widthAnchor.constraint(equalToConstant: 460).isActive = true

            // Entity selection
            stack.addArrangedSubview(self.createLabeledControl(
                label: "Entity:",
                control: {
                    self.entityPopup = NSPopUpButton()
                    self.entityPopup.target = self
                    self.entityPopup.action = #selector(self.entityChanged)
                    return self.entityPopup
                }(),
            ))

            // Target field
            stack.addArrangedSubview(self.createLabeledControl(
                label: "Set field:",
                control: {
                    self.targetFieldPopup = NSPopUpButton()
                    return self.targetFieldPopup
                }(),
            ))

            // New value
            stack.addArrangedSubview(self.createLabeledControl(
                label: "To value:",
                control: {
                    self.newValueField = NSTextField()
                    self.newValueField.placeholderString = "New value"
                    return self.newValueField
                }(),
            ))

            // Where field
            stack.addArrangedSubview(self.createLabeledControl(
                label: "Where field:",
                control: {
                    self.whereFieldPopup = NSPopUpButton()
                    return self.whereFieldPopup
                }(),
            ))

            // Where value
            stack.addArrangedSubview(self.createLabeledControl(
                label: "Equals:",
                control: {
                    self.whereValueField = NSTextField()
                    self.whereValueField.placeholderString = "Match value"
                    return self.whereValueField
                }(),
            ))

            // Increment version checkbox
            self.incrementVersionCheckbox = NSButton(checkboxWithTitle: "Increment version (for PolyBase sync)", target: nil, action: nil)
            self.incrementVersionCheckbox.state = .on
            stack.addArrangedSubview(self.incrementVersionCheckbox)

            // Error label
            self.errorLabel = NSTextField(labelWithString: "")
            self.errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
            self.errorLabel.textColor = .systemRed
            self.errorLabel.isHidden = true
            self.errorLabel.maximumNumberOfLines = 3
            self.errorLabel.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(self.errorLabel)
            self.errorLabel.widthAnchor.constraint(equalToConstant: 460).isActive = true

            // Buttons
            let buttonStack = NSStackView()
            buttonStack.orientation = .horizontal
            buttonStack.spacing = 12

            let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
            cancelButton.bezelStyle = .rounded
            buttonStack.addArrangedSubview(cancelButton)

            self.previewButton = NSButton(title: "Preview →", target: self, action: #selector(self.preview))
            self.previewButton.bezelStyle = .rounded
            self.previewButton.keyEquivalent = "\r"
            buttonStack.addArrangedSubview(self.previewButton)

            stack.addArrangedSubview(buttonStack)

            // Layout
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: view.topAnchor),
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                view.widthAnchor.constraint(equalToConstant: 500),
            ])
        }

        private func createLabeledControl(label: String, control: NSView) -> NSView {
            let container = NSStackView()
            container.orientation = .horizontal
            container.spacing = 8
            container.alignment = .centerY

            let labelView = NSTextField(labelWithString: label)
            labelView.font = .systemFont(ofSize: 12, weight: .medium)
            labelView.alignment = .right
            labelView.widthAnchor.constraint(equalToConstant: 90).isActive = true
            container.addArrangedSubview(labelView)

            control.translatesAutoresizingMaskIntoConstraints = false
            if let textField = control as? NSTextField {
                textField.widthAnchor.constraint(equalToConstant: 370).isActive = true
            } else if let popup = control as? NSPopUpButton {
                popup.widthAnchor.constraint(equalToConstant: 370).isActive = true
            }
            container.addArrangedSubview(control)

            return container
        }

        // MARK: Population

        private func populateEntityPopup() {
            self.entityPopup.removeAllItems()

            for entity in self.dataSource.configuration.entities {
                self.entityPopup.addItem(withTitle: entity.displayName)
            }

            // Select current entity
            if let currentIndex = dataSource.configuration.entityIndex(withID: dataSource.currentEntity?.id ?? "") {
                self.entityPopup.selectItem(at: currentIndex)
            } else {
                self.entityPopup.selectItem(at: 0)
            }

            self.entityChanged()
        }

        @objc private func entityChanged() {
            let selectedIndex = self.entityPopup.indexOfSelectedItem
            guard selectedIndex >= 0, selectedIndex < self.dataSource.configuration.entities.count else { return }

            self.currentEntity = self.dataSource.configuration.entities[selectedIndex]
            self.updateFieldPopups()
        }

        private func updateFieldPopups() {
            guard let entity = currentEntity else { return }

            // Get all text fields (editable and read-only)
            self.allFields = entity.detailFields.filter { !$0.isToggle }
            self.editableFields = self.allFields.filter(\.isEditable)

            // Populate target field (editable only)
            self.targetFieldPopup.removeAllItems()
            for field in self.editableFields {
                self.targetFieldPopup.addItem(withTitle: field.label)
            }

            // Populate where field (all text fields)
            self.whereFieldPopup.removeAllItems()
            for field in self.allFields {
                self.whereFieldPopup.addItem(withTitle: field.label)
            }

            self.errorLabel.isHidden = true
        }

        @objc private func cancel() {
            self.dismiss(nil)
        }

        @objc private func preview() {
            self.errorLabel.isHidden = true

            // Build operation
            guard let entity = currentEntity else { return }

            let targetIndex = self.targetFieldPopup.indexOfSelectedItem
            let whereIndex = self.whereFieldPopup.indexOfSelectedItem

            guard targetIndex >= 0, targetIndex < self.editableFields.count else {
                self.showError("Please select a target field")
                return
            }

            guard whereIndex >= 0, whereIndex < self.allFields.count else {
                self.showError("Please select a where field")
                return
            }

            let operation = BulkEditOperation(
                entityID: entity.id,
                targetField: self.editableFields[targetIndex],
                newValue: self.newValueField.stringValue,
                whereField: self.allFields[whereIndex],
                whereValue: self.whereValueField.stringValue,
                incrementVersion: self.incrementVersionCheckbox.state == .on,
            )

            // Validate
            let validator = BulkEditValidator(dataSource: dataSource)
            let errors = validator.validate(operation)

            if !errors.isEmpty {
                self.showError(errors.joined(separator: "\n"))
                return
            }

            // Generate preview
            guard let preview = validator.preview(operation, limit: 5) else {
                self.showError("Failed to generate preview")
                return
            }

            if preview.totalCount == 0 {
                self.showError("No records match the specified condition")
                return
            }

            // Show preview panel
            self.showPreviewPanel(operation: operation, preview: preview)
        }

        private func showError(_ message: String) {
            self.errorLabel.stringValue = message
            self.errorLabel.isHidden = false
        }

        private func showPreviewPanel(operation: BulkEditOperation, preview: BulkEditPreview) {
            let previewPanel = macOSBulkEditPreviewPanel(
                dataSource: dataSource,
                operation: operation,
                preview: preview,
            )

            presentAsSheet(previewPanel)
        }
    }

    // MARK: - macOSBulkEditPreviewPanel

    /// Preview panel showing affected records and allowing final confirmation.
    @MainActor
    final class macOSBulkEditPreviewPanel: NSViewController {
        private let dataSource: PolyDataExplorerDataSource
        private let operation: BulkEditOperation
        private let preview: BulkEditPreview

        private var tableView: NSTableView!
        private var scrollView: NSScrollView!
        private var applyButton: NSButton!

        // MARK: Initialization

        init(dataSource: PolyDataExplorerDataSource, operation: BulkEditOperation, preview: BulkEditPreview) {
            self.dataSource = dataSource
            self.operation = operation
            self.preview = preview
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            self.setupUI()
        }

        // MARK: Setup

        private func setupUI() {
            view.wantsLayer = true

            let stack = NSStackView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            view.addSubview(stack)

            // Title
            let titleLabel = NSTextField(labelWithString: "Confirm Bulk Edit")
            titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            stack.addArrangedSubview(titleLabel)

            // Summary
            let summaryText = self.preview.hasMore
                ? "Showing first 5 of \(self.preview.totalCount) matching records. All \(self.preview.totalCount) will be updated."
                : "\(self.preview.totalCount) record(s) will be updated:"
            let summaryLabel = NSTextField(labelWithString: summaryText)
            summaryLabel.font = .systemFont(ofSize: 11)
            summaryLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(summaryLabel)

            // Table view
            self.tableView = NSTableView()
            self.tableView.style = .inset
            self.tableView.usesAlternatingRowBackgroundColors = true
            self.tableView.allowsMultipleSelection = false
            self.tableView.allowsColumnSelection = false
            self.tableView.headerView = NSTableHeaderView()
            self.tableView.delegate = self
            self.tableView.dataSource = self

            let recordColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("record"))
            recordColumn.title = "Record"
            recordColumn.width = 200
            recordColumn.minWidth = 150
            self.tableView.addTableColumn(recordColumn)

            let currentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("current"))
            currentColumn.title = "Current Value"
            currentColumn.width = 150
            currentColumn.minWidth = 100
            self.tableView.addTableColumn(currentColumn)

            let newColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("new"))
            newColumn.title = "New Value"
            newColumn.width = 150
            newColumn.minWidth = 100
            self.tableView.addTableColumn(newColumn)

            self.scrollView = NSScrollView()
            self.scrollView.translatesAutoresizingMaskIntoConstraints = false
            self.scrollView.documentView = self.tableView
            self.scrollView.hasVerticalScroller = true
            self.scrollView.hasHorizontalScroller = true
            self.scrollView.autohidesScrollers = true
            self.scrollView.borderType = .noBorder
            stack.addArrangedSubview(self.scrollView)

            self.scrollView.widthAnchor.constraint(equalToConstant: 560).isActive = true
            self.scrollView.heightAnchor.constraint(equalToConstant: 200).isActive = true

            // Buttons
            let buttonStack = NSStackView()
            buttonStack.orientation = .horizontal
            buttonStack.spacing = 12

            let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
            cancelButton.bezelStyle = .rounded
            buttonStack.addArrangedSubview(cancelButton)

            self.applyButton = NSButton(title: "Apply Changes", target: self, action: #selector(self.apply))
            self.applyButton.bezelStyle = .rounded
            self.applyButton.keyEquivalent = "\r"
            buttonStack.addArrangedSubview(self.applyButton)

            stack.addArrangedSubview(buttonStack)

            // Layout
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: view.topAnchor),
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                view.widthAnchor.constraint(equalToConstant: 600),
            ])
        }

        @objc private func cancel() {
            self.dismiss(nil)
        }

        @objc private func apply() {
            self.applyButton.isEnabled = false
            self.applyButton.title = "Applying..."

            Task {
                let executor = BulkEditExecutor(dataSource: dataSource)
                let result = await executor.execute(preview: self.preview, operation: self.operation)

                if result.isSuccess {
                    self.dataSource.context.reloadData?()
                    self.dismiss(nil)
                    self.presentingViewController?.dismiss(nil)

                    self.dataSource.context.showAlert?(
                        "Bulk Edit Complete",
                        "Successfully updated \(result.updatedCount) record(s).")
                } else {
                    self.applyButton.isEnabled = true
                    self.applyButton.title = "Apply Changes"

                    self.dataSource.context.showAlert?(
                        "Bulk Edit Failed",
                        result.error ?? "Unknown error")
                }
            }
        }
    }

    // MARK: - NSTableViewDataSource

    extension macOSBulkEditPreviewPanel: NSTableViewDataSource {
        func numberOfRows(in _: NSTableView) -> Int {
            self.preview.matchingRecords.count
        }
    }

    // MARK: - NSTableViewDelegate

    extension macOSBulkEditPreviewPanel: NSTableViewDelegate {
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < self.preview.matchingRecords.count else { return nil }
            let record = self.preview.matchingRecords[row]

            let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell")
            let cell: NSTextField

            if let existingCell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
                cell = existingCell
            } else {
                cell = NSTextField()
                cell.identifier = identifier
                cell.isBordered = false
                cell.drawsBackground = false
                cell.isEditable = false
                cell.lineBreakMode = .byTruncatingTail
                cell.font = .systemFont(ofSize: 11)
            }

            switch identifier.rawValue {
            case "record":
                cell.stringValue = record.displayName

            case "current":
                cell.stringValue = record.currentValue

            case "new":
                cell.stringValue = record.newValue
                cell.textColor = .systemBlue

            default:
                cell.stringValue = ""
            }

            return cell
        }
    }

#endif // os(macOS)
