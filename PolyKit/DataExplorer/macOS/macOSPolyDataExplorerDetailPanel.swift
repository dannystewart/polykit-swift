#if os(macOS)

    import AppKit

    // MARK: - macOSPolyDataExplorerDetailPanel

    /// Detail panel for displaying field information about a selected record.
    @MainActor
    public final class macOSPolyDataExplorerDetailPanel: NSViewController {
        // MARK: Properties

        private let dataSource: PolyDataExplorerDataSource
        private var currentRecord: AnyObject?
        private var currentEntity: AnyPolyDataEntity?

        private var scrollView: NSScrollView!
        private var stackView: NSStackView!
        private var emptyLabel: NSTextField!

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

        override public func loadView() {
            view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        override public func viewDidLoad() {
            super.viewDidLoad()
            setupUI()
            showEmpty()
        }

        // MARK: Setup

        private func setupUI() {
            // Empty state label
            emptyLabel = NSTextField(labelWithString: "Select a record to view details")
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.alignment = .center
            view.addSubview(emptyLabel)

            // Stack view for fields
            stackView = NSStackView()
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.orientation = .vertical
            stackView.alignment = .leading
            stackView.spacing = 12
            stackView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

            scrollView = NSScrollView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.documentView = stackView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.isHidden = true
            view.addSubview(scrollView)

            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

                scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
                stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            ])
        }

        // MARK: Public Methods

        public func showRecord(_ record: AnyObject?, entity: AnyPolyDataEntity?) {
            currentRecord = record
            currentEntity = entity

            guard let record, let entity else {
                showEmpty()
                return
            }

            buildFields(for: record, entity: entity)
        }

        public func showEmpty() {
            emptyLabel.isHidden = false
            scrollView.isHidden = true

            // Clear stack view
            for subview in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }
        }

        public func refresh() {
            if let record = currentRecord, let entity = currentEntity {
                showRecord(record, entity: entity)
            }
        }

        // MARK: Private Methods

        private func buildFields(for record: AnyObject, entity: AnyPolyDataEntity) {
            emptyLabel.isHidden = true
            scrollView.isHidden = false

            // Clear existing fields
            for subview in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }

            // Add header
            let header = NSTextField(labelWithString: "\(entity.displayName) Details")
            header.font = .systemFont(ofSize: 14, weight: .semibold)
            stackView.addArrangedSubview(header)

            // Add separator
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -24).isActive = true

            // Add fields section header
            if !entity.detailFields.isEmpty {
                let fieldsHeader = NSTextField(labelWithString: "Fields")
                fieldsHeader.font = .systemFont(ofSize: 12, weight: .medium)
                fieldsHeader.textColor = .secondaryLabelColor
                stackView.addArrangedSubview(fieldsHeader)
            }

            // Add detail fields
            for field in entity.detailFields {
                let fieldView = createFieldView(field: field, record: record)
                stackView.addArrangedSubview(fieldView)
            }

            // Add relationships section
            if !entity.detailRelationships.isEmpty {
                let relHeader = NSTextField(labelWithString: "Relationships")
                relHeader.font = .systemFont(ofSize: 12, weight: .medium)
                relHeader.textColor = .secondaryLabelColor
                stackView.addArrangedSubview(relHeader)

                for relationship in entity.detailRelationships {
                    let relView = createRelationshipView(relationship: relationship, record: record)
                    stackView.addArrangedSubview(relView)
                }
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
                    checkbox.tag = currentEntity?.detailFields.firstIndex(where: { $0.label == field.label }) ?? 0
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
                    scrollView.heightAnchor.constraint(equalToConstant: 100).isActive = true
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
            let button = NSButton(title: "\(relationship.label): \(relationship.getValue(record))", target: self, action: #selector(relationshipClicked(_:)))
            button.bezelStyle = .inline
            button.tag = currentEntity?.detailRelationships.firstIndex(where: { $0.label == relationship.label }) ?? 0
            return button
        }

        @objc private func relationshipClicked(_ sender: NSButton) {
            guard let record = currentRecord,
                  let entity = currentEntity,
                  sender.tag < entity.detailRelationships.count else { return }

            let relationship = entity.detailRelationships[sender.tag]
            relationship.navigateAction(record, dataSource.context)
        }

    }

#endif // os(macOS)
