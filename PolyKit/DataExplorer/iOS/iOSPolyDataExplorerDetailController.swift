//
//  iOSPolyDataExplorerDetailController.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(iOS)

    import UIKit

    // MARK: - iOSPolyDataExplorerDetailController

    /// Detail view controller for viewing and editing individual records.
    @MainActor
    public final class iOSPolyDataExplorerDetailController: UITableViewController {
        // MARK: Types

        private enum Section: Int, CaseIterable {
            case fields
            case relationships
            case actions
        }

        private var record: AnyObject?
        private var entity: AnyPolyDataEntity?
        private let dataSource: PolyDataExplorerDataSource

        private let emptyStateLabel: UILabel = .init()

        // MARK: Initialization

        public init(
            record: AnyObject,
            entity: AnyPolyDataEntity,
            dataSource: PolyDataExplorerDataSource,
        ) {
            self.record = record
            self.entity = entity
            self.dataSource = dataSource
            super.init(style: .insetGrouped)
        }

        public init(dataSource: PolyDataExplorerDataSource) {
            self.record = nil
            self.entity = nil
            self.dataSource = dataSource
            super.init(style: .insetGrouped)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public func viewDidLoad() {
            super.viewDidLoad()
            self.setupUI()
            self.setupEmptyState()
            self.updateEmptyState()
        }

        // MARK: UITableViewDataSource

        override public func numberOfSections(in _: UITableView) -> Int {
            guard self.record != nil, self.entity != nil else { return 0 }
            return Section.allCases.count
        }

        override public func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
            guard let entity, record != nil else { return 0 }
            guard let sectionType = Section(rawValue: section) else { return 0 }
            return switch sectionType {
            case .fields: entity.detailFields.count
            case .relationships: entity.detailRelationships.count
            case .actions: 1
            }
        }

        override public func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
            guard let entity, record != nil else { return nil }
            guard let sectionType = Section(rawValue: section) else { return nil }
            return switch sectionType {
            case .fields: entity.detailFields.isEmpty ? nil : "Fields"
            case .relationships: entity.detailRelationships.isEmpty ? nil : "Relationships"
            case .actions: nil
            }
        }

        override public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            guard let entity, let record else {
                return UITableViewCell()
            }
            guard let sectionType = Section(rawValue: indexPath.section) else {
                return UITableViewCell()
            }

            switch sectionType {
            case .fields:
                return self.fieldCell(at: indexPath, tableView: tableView, entity: entity, record: record)
            case .relationships:
                return self.relationshipCell(at: indexPath, tableView: tableView, entity: entity, record: record)
            case .actions:
                return self.deleteCell(tableView: tableView)
            }
        }

        // MARK: UITableViewDelegate

        override public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)

            guard let entity, let record else { return }
            guard let sectionType = Section(rawValue: indexPath.section) else { return }

            switch sectionType {
            case .fields:
                break // Fields handle their own editing

            case .relationships:
                guard indexPath.row < entity.detailRelationships.count else { return }
                let relationship = entity.detailRelationships[indexPath.row]
                relationship.navigateAction(record, self.dataSource.context)

            case .actions:
                self.confirmDelete()
            }
        }

        override public func tableView(_: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            guard let entity, record != nil else { return 44 }
            guard let sectionType = Section(rawValue: indexPath.section) else { return 44 }

            if sectionType == .fields, indexPath.row < entity.detailFields.count {
                let field = entity.detailFields[indexPath.row]
                if field.isMultiline {
                    return 280
                }
            }

            return UITableView.automaticDimension
        }

        // MARK: Public API

        public func setRecord(_ record: AnyObject?, entity: AnyPolyDataEntity?) {
            self.record = record
            self.entity = entity
            self.updateEmptyState()
            self.tableView.reloadData()
        }

        // MARK: Setup

        private func setupUI() {
            self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
            self.tableView.register(PolyTextFieldCell.self, forCellReuseIdentifier: PolyTextFieldCell.reuseIdentifier)
            self.tableView.register(PolyTextViewCell.self, forCellReuseIdentifier: PolyTextViewCell.reuseIdentifier)
            self.tableView.register(PolyToggleCell.self, forCellReuseIdentifier: PolyToggleCell.reuseIdentifier)
        }

        private func setupEmptyState() {
            self.emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
            self.emptyStateLabel.text = "Select a record to view details"
            self.emptyStateLabel.textAlignment = .center
            self.emptyStateLabel.textColor = .secondaryLabel
            self.emptyStateLabel.numberOfLines = 0
            self.tableView.backgroundView = self.emptyStateLabel
        }

        private func updateEmptyState() {
            let hasRecord = (record != nil && entity != nil)
            self.emptyStateLabel.isHidden = hasRecord
            self.tableView.separatorStyle = hasRecord ? .singleLine : .none

            if let entity {
                title = "\(entity.displayName) Details"
            } else {
                title = "Inspector"
            }
        }

        // MARK: Cell Builders

        private func fieldCell(
            at indexPath: IndexPath,
            tableView: UITableView,
            entity: AnyPolyDataEntity,
            record: AnyObject,
        ) -> UITableViewCell {
            guard indexPath.row < entity.detailFields.count else { return UITableViewCell() }
            let field = entity.detailFields[indexPath.row]

            if field.isToggle {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: PolyToggleCell.reuseIdentifier,
                    for: indexPath,
                ) as! PolyToggleCell
                let isOn = field.getToggleValue?(record) ?? false
                cell.configure(label: field.label, isOn: isOn) { [weak self] newValue in
                    guard let self else { return }
                    field.toggleAction?(record, newValue)
                    self.dataSource.save()
                }
                return cell
            }

            if field.isEditable {
                if field.isMultiline {
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: PolyTextViewCell.reuseIdentifier,
                        for: indexPath,
                    ) as! PolyTextViewCell
                    cell.configure(label: field.label, value: field.getValue(record)) { [weak self] newValue in
                        guard let self else { return }
                        field.editAction?(record, newValue)
                        self.dataSource.save()
                    }
                    return cell
                } else {
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: PolyTextFieldCell.reuseIdentifier,
                        for: indexPath,
                    ) as! PolyTextFieldCell
                    cell.configure(label: field.label, value: field.getValue(record)) { [weak self] newValue in
                        guard let self else { return }
                        field.editAction?(record, newValue)
                        self.dataSource.save()
                    }
                    return cell
                }
            }

            // Read-only field
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = field.label
            config.secondaryText = field.getValue(record)
            config.secondaryTextProperties.color = .secondaryLabel
            config.secondaryTextProperties.numberOfLines = 3
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }

        private func relationshipCell(
            at indexPath: IndexPath,
            tableView: UITableView,
            entity: AnyPolyDataEntity,
            record: AnyObject,
        ) -> UITableViewCell {
            guard indexPath.row < entity.detailRelationships.count else { return UITableViewCell() }
            let relationship = entity.detailRelationships[indexPath.row]

            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var config = cell.defaultContentConfiguration()
            config.text = relationship.label
            config.secondaryText = relationship.getValue(record)
            config.textProperties.color = .systemBlue
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        private func deleteCell(tableView: UITableView) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell") ?? UITableViewCell()
            var config = cell.defaultContentConfiguration()
            config.text = "Delete Record"
            config.textProperties.color = .systemRed
            config.textProperties.alignment = .center
            cell.contentConfiguration = config
            cell.accessoryType = .none
            return cell
        }

        // MARK: Delete

        private func confirmDelete() {
            guard let entity else { return }
            let alert = UIAlertController(
                title: "Delete \(entity.displayName)?",
                message: "This action cannot be undone.",
                preferredStyle: .alert,
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.performDelete()
            })

            present(alert, animated: true)
        }

        private func performDelete() {
            guard let record else { return }
            Task {
                await self.dataSource.deleteRecord(record)
                self.dataSource.context.reloadData?()

                if splitViewController?.isCollapsed == true {
                    splitViewController?.show(.primary)
                } else {
                    self.setRecord(nil, entity: nil)
                }
            }
        }
    }

    // MARK: - PolyTextFieldCell

    private final class PolyTextFieldCell: UITableViewCell, UITextFieldDelegate {
        static let reuseIdentifier = "PolyTextFieldCell"

        private let label: UILabel = .init()
        private let textField: UITextField = .init()
        private var editAction: ((String) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(label: String, value: String, action: ((String) -> Void)?) {
            self.label.text = label
            self.textField.text = value
            self.editAction = action
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            self.editAction?(textField.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        private func setupUI() {
            selectionStyle = .none

            self.label.font = .systemFont(ofSize: 14)
            self.label.textColor = .secondaryLabel
            self.label.translatesAutoresizingMaskIntoConstraints = false

            self.textField.font = .systemFont(ofSize: 14)
            self.textField.borderStyle = .roundedRect
            self.textField.translatesAutoresizingMaskIntoConstraints = false
            self.textField.delegate = self

            contentView.addSubview(self.label)
            contentView.addSubview(self.textField)

            NSLayoutConstraint.activate([
                self.label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                self.label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                self.textField.topAnchor.constraint(equalTo: self.label.bottomAnchor, constant: 4),
                self.textField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                self.textField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            ])
        }
    }

    // MARK: - PolyTextViewCell

    private final class PolyTextViewCell: UITableViewCell, UITextViewDelegate {
        static let reuseIdentifier = "PolyTextViewCell"

        private let label: UILabel = .init()
        private let textView: UITextView = .init()
        private var editAction: ((String) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(label: String, value: String, action: ((String) -> Void)?) {
            self.label.text = label
            self.textView.text = value
            self.editAction = action
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            self.editAction?(textView.text)
        }

        private func setupUI() {
            selectionStyle = .none

            self.label.font = .systemFont(ofSize: 14)
            self.label.textColor = .secondaryLabel
            self.label.translatesAutoresizingMaskIntoConstraints = false

            self.textView.font = .systemFont(ofSize: 14)
            self.textView.layer.borderColor = UIColor.separator.cgColor
            self.textView.layer.borderWidth = 0.5
            self.textView.layer.cornerRadius = 6
            self.textView.translatesAutoresizingMaskIntoConstraints = false
            self.textView.delegate = self

            contentView.addSubview(self.label)
            contentView.addSubview(self.textView)

            NSLayoutConstraint.activate([
                self.label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                self.label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                self.textView.topAnchor.constraint(equalTo: self.label.bottomAnchor, constant: 4),
                self.textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                self.textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
                self.textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            ])
        }
    }

    // MARK: - PolyToggleCell

    private final class PolyToggleCell: UITableViewCell {
        static let reuseIdentifier = "PolyToggleCell"

        private let label: UILabel = .init()
        private let toggle: UISwitch = .init()
        private var toggleAction: ((Bool) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(label: String, isOn: Bool, action: ((Bool) -> Void)?) {
            self.label.text = label
            self.toggle.isOn = isOn
            self.toggleAction = action
        }

        private func setupUI() {
            selectionStyle = .none

            self.label.font = .systemFont(ofSize: 14)
            self.label.translatesAutoresizingMaskIntoConstraints = false

            self.toggle.translatesAutoresizingMaskIntoConstraints = false
            self.toggle.addTarget(self, action: #selector(self.toggleChanged), for: .valueChanged)

            contentView.addSubview(self.label)
            contentView.addSubview(self.toggle)

            NSLayoutConstraint.activate([
                self.label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

                self.toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                self.toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }

        @objc private func toggleChanged() {
            self.toggleAction?(self.toggle.isOn)
        }
    }

#endif // os(iOS)
