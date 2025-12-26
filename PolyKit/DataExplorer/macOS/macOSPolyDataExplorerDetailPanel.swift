//
//  macOSPolyDataExplorerDetailPanel.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(macOS)

    import AppKit

    // MARK: - macOSPolyDataExplorerDetailPanel

    /// Detail panel for displaying field information about a selected record.
    @MainActor
    public final class macOSPolyDataExplorerDetailPanel: NSViewController {
        private let dataSource: PolyDataExplorerDataSource
        private var currentRecord: AnyObject?
        private var currentEntity: AnyPolyDataEntity?

        private var scrollView: NSScrollView!
        private var stackView: NSStackView!
        private var emptyLabel: NSTextField!
        private var saveButton: NSButton?

        /// Whether explicit save is required (from configuration).
        private var requiresExplicitSave: Bool {
            self.dataSource.configuration.requiresExplicitSave
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

        override public func loadView() {
            view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        override public func viewDidLoad() {
            super.viewDidLoad()
            self.setupUI()
            self.showEmpty()
        }

        // MARK: Public Methods

        public func showRecord(_ record: AnyObject?, entity: AnyPolyDataEntity?) {
            self.currentRecord = record
            self.currentEntity = entity

            guard let record, let entity else {
                self.showEmpty()
                return
            }

            self.buildFields(for: record, entity: entity)
        }

        public func showEmpty() {
            self.emptyLabel.isHidden = false
            self.scrollView.isHidden = true

            // Clear stack view
            for subview in self.stackView.arrangedSubviews {
                self.stackView.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }
        }

        public func refresh() {
            if let record = currentRecord, let entity = currentEntity {
                self.showRecord(record, entity: entity)
            }
        }

        // MARK: Setup

        private func setupUI() {
            // Empty state label
            self.emptyLabel = NSTextField(labelWithString: "Select a record to view details")
            self.emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            self.emptyLabel.textColor = .secondaryLabelColor
            self.emptyLabel.alignment = .center
            view.addSubview(self.emptyLabel)

            // Stack view for fields - use a flipped clip view to pin content to top
            self.stackView = NSStackView()
            self.stackView.translatesAutoresizingMaskIntoConstraints = false
            self.stackView.orientation = .vertical
            self.stackView.alignment = .leading
            self.stackView.spacing = 12
            self.stackView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

            // Use a flipped clip view so content stays at top
            let flippedClipView = FlippedClipView()
            flippedClipView.documentView = self.stackView

            self.scrollView = NSScrollView()
            self.scrollView.translatesAutoresizingMaskIntoConstraints = false
            self.scrollView.contentView = flippedClipView
            self.scrollView.hasVerticalScroller = true
            self.scrollView.hasHorizontalScroller = false
            self.scrollView.autohidesScrollers = true
            self.scrollView.borderType = .noBorder
            self.scrollView.isHidden = true
            view.addSubview(self.scrollView)

            NSLayoutConstraint.activate([
                self.emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                self.emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

                self.scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                self.scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                self.scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                self.scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                self.stackView.topAnchor.constraint(equalTo: self.scrollView.contentView.topAnchor),
                self.stackView.leadingAnchor.constraint(equalTo: self.scrollView.contentView.leadingAnchor),
                self.stackView.trailingAnchor.constraint(equalTo: self.scrollView.contentView.trailingAnchor),
            ])
        }

        // MARK: Private Methods

        private func buildFields(for record: AnyObject, entity: AnyPolyDataEntity) {
            self.emptyLabel.isHidden = true
            self.scrollView.isHidden = false

            // Clear existing fields
            for subview in self.stackView.arrangedSubviews {
                self.stackView.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }

            // Add header
            let header = NSTextField(labelWithString: "\(entity.displayName) Details")
            header.font = .systemFont(ofSize: 14, weight: .semibold)
            self.stackView.addArrangedSubview(header)

            // Add separator
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            self.stackView.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: self.stackView.widthAnchor, constant: -24).isActive = true

            // Add fields section header
            if !entity.detailFields.isEmpty {
                let fieldsHeader = NSTextField(labelWithString: "Fields")
                fieldsHeader.font = .systemFont(ofSize: 12, weight: .medium)
                fieldsHeader.textColor = .secondaryLabelColor
                self.stackView.addArrangedSubview(fieldsHeader)
            }

            // Add detail fields
            for field in entity.detailFields {
                let fieldView = self.createFieldView(field: field, record: record)
                self.stackView.addArrangedSubview(fieldView)
            }

            // Add relationships section
            if !entity.detailRelationships.isEmpty {
                let relHeader = NSTextField(labelWithString: "Relationships")
                relHeader.font = .systemFont(ofSize: 12, weight: .medium)
                relHeader.textColor = .secondaryLabelColor
                self.stackView.addArrangedSubview(relHeader)

                for relationship in entity.detailRelationships {
                    let relView = self.createRelationshipView(relationship: relationship, record: record)
                    self.stackView.addArrangedSubview(relView)
                }
            }

            // Add Save button if explicit save is required
            if self.requiresExplicitSave {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                self.stackView.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: self.stackView.widthAnchor, constant: -24).isActive = true

                let button = NSButton(title: "Save Changes", target: self, action: #selector(saveButtonClicked))
                button.bezelStyle = .rounded
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: 250).isActive = true
                self.stackView.addArrangedSubview(button)
                self.saveButton = button
            }
        }

        private func createFieldView(field: PolyDataField, record: AnyObject) -> NSView {
            let container = NSStackView()
            container.orientation = .vertical
            container.alignment = .leading
            container.spacing = 2

            let label = NSTextField(labelWithString: field.label)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            container.addArrangedSubview(label)

            if field.isToggle {
                let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                checkbox.state = (field.getToggleValue?(record) ?? false) ? .on : .off
                checkbox.isEnabled = field.toggleAction != nil
                if field.toggleAction != nil {
                    checkbox.target = self
                    checkbox.tag = self.currentEntity?.detailFields.firstIndex(where: { $0.label == field.label }) ?? 0
                }
                container.addArrangedSubview(checkbox)
            } else if field.isEditable {
                let textField: NSTextField
                if field.isMultiline {
                    let scrollView = NSScrollView()
                    scrollView.translatesAutoresizingMaskIntoConstraints = false
                    let textView = NSTextView()
                    textView.string = field.getValue(record)
                    textView.font = .systemFont(ofSize: 11)
                    textView.isEditable = true
                    scrollView.documentView = textView
                    scrollView.hasVerticalScroller = true
                    scrollView.heightAnchor.constraint(equalToConstant: 200).isActive = true
                    scrollView.widthAnchor.constraint(equalToConstant: 250).isActive = true
                    container.addArrangedSubview(scrollView)
                } else {
                    textField = NSTextField()
                    textField.stringValue = field.getValue(record)
                    textField.font = .systemFont(ofSize: 11)
                    textField.isEditable = true
                    textField.isBordered = true
                    textField.bezelStyle = .roundedBezel
                    textField.translatesAutoresizingMaskIntoConstraints = false
                    textField.widthAnchor.constraint(equalToConstant: 250).isActive = true
                    container.addArrangedSubview(textField)
                }
            } else {
                let value = NSTextField(labelWithString: field.getValue(record))
                value.font = .systemFont(ofSize: 11)
                value.lineBreakMode = .byTruncatingTail
                value.maximumNumberOfLines = 3
                value.translatesAutoresizingMaskIntoConstraints = false
                value.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
                container.addArrangedSubview(value)
            }

            return container
        }

        private func createRelationshipView(relationship: PolyDataRelationship, record: AnyObject) -> NSView {
            let button = NSButton(title: "\(relationship.label): \(relationship.getValue(record))", target: self, action: #selector(self.relationshipClicked(_:)))
            button.bezelStyle = .inline
            button.tag = self.currentEntity?.detailRelationships.firstIndex(where: { $0.label == relationship.label }) ?? 0
            return button
        }

        @objc private func relationshipClicked(_ sender: NSButton) {
            guard
                let record = currentRecord,
                let entity = currentEntity,
                sender.tag < entity.detailRelationships.count else { return }

            let relationship = entity.detailRelationships[sender.tag]
            relationship.navigateAction(record, self.dataSource.context)
        }

        @objc private func saveButtonClicked() {
            guard let record = currentRecord else { return }
            guard let onSave = dataSource.configuration.onSave else {
                // Fallback: just save context if no custom save handler
                self.dataSource.save()
                return
            }

            // Capture modelContext on MainActor before passing to nonisolated Task
            let modelContext = self.dataSource.modelContext

            Task {
                do {
                    try await onSave(record, modelContext)
                    await MainActor.run {
                        // Reload to show updated values
                        self.refresh()
                        self.dataSource.context.reloadData?()
                    }
                } catch {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Save Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    // MARK: - FlippedClipView

    /// A clip view that flips its coordinate system so content pins to the top.
    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

#endif // os(macOS)
