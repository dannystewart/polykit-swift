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

        // MARK: Properties

        private let record: AnyObject
        private let entity: AnyPolyDataEntity
        private let dataSource: PolyDataExplorerDataSource

        // MARK: Initialization

        public init(
            record: AnyObject,
            entity: AnyPolyDataEntity,
            dataSource: PolyDataExplorerDataSource
        ) {
            self.record = record
            self.entity = entity
            self.dataSource = dataSource
            super.init(style: .insetGrouped)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Lifecycle

        override public func viewDidLoad() {
            super.viewDidLoad()
            title = "\(entity.displayName) Details"
            setupUI()
        }

        // MARK: Setup

        private func setupUI() {
            tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
            tableView.register(PolyTextFieldCell.self, forCellReuseIdentifier: PolyTextFieldCell.reuseIdentifier)
            tableView.register(PolyTextViewCell.self, forCellReuseIdentifier: PolyTextViewCell.reuseIdentifier)
            tableView.register(PolyToggleCell.self, forCellReuseIdentifier: PolyToggleCell.reuseIdentifier)
        }

        // MARK: UITableViewDataSource

        override public func numberOfSections(in _: UITableView) -> Int {
            Section.allCases.count
        }

        override public func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
            guard let sectionType = Section(rawValue: section) else { return 0 }
            return switch sectionType {
            case .fields: entity.detailFields.count
            case .relationships: entity.detailRelationships.count
            case .actions: 1
            }
        }

        override public func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
            guard let sectionType = Section(rawValue: section) else { return nil }
            return switch sectionType {
            case .fields: entity.detailFields.isEmpty ? nil : "Fields"
            case .relationships: entity.detailRelationships.isEmpty ? nil : "Relationships"
            case .actions: nil
            }
        }

        override public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            guard let sectionType = Section(rawValue: indexPath.section) else {
                return UITableViewCell()
            }

            switch sectionType {
            case .fields:
                return fieldCell(at: indexPath, tableView: tableView)
            case .relationships:
                return relationshipCell(at: indexPath, tableView: tableView)
            case .actions:
                return deleteCell(tableView: tableView)
            }
        }

        // MARK: UITableViewDelegate

        override public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)

            guard let sectionType = Section(rawValue: indexPath.section) else { return }

            switch sectionType {
            case .fields:
                break // Fields handle their own editing

            case .relationships:
                guard indexPath.row < entity.detailRelationships.count else { return }
                let relationship = entity.detailRelationships[indexPath.row]
                relationship.navigateAction(record, dataSource.context)

            case .actions:
                confirmDelete()
            }
        }

        override public func tableView(_: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            guard let sectionType = Section(rawValue: indexPath.section) else { return 44 }

            if sectionType == .fields, indexPath.row < entity.detailFields.count {
                let field = entity.detailFields[indexPath.row]
                if field.isMultiline {
                    return 280
                }
            }

            return UITableView.automaticDimension
        }

        // MARK: Cell Builders

        private func fieldCell(at indexPath: IndexPath, tableView: UITableView) -> UITableViewCell {
            guard indexPath.row < entity.detailFields.count else { return UITableViewCell() }
            let field = entity.detailFields[indexPath.row]

            if field.isToggle {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: PolyToggleCell.reuseIdentifier,
                    for: indexPath
                ) as! PolyToggleCell
                let isOn = field.getToggleValue?(record) ?? false
                cell.configure(label: field.label, isOn: isOn) { [weak self] newValue in
                    guard let self else { return }
                    field.toggleAction?(record, newValue)
                    dataSource.save()
                }
                return cell
            }

            if field.isEditable {
                if field.isMultiline {
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: PolyTextViewCell.reuseIdentifier,
                        for: indexPath
                    ) as! PolyTextViewCell
                    cell.configure(label: field.label, value: field.getValue(record)) { [weak self] newValue in
                        guard let self else { return }
                        field.editAction?(record, newValue)
                        dataSource.save()
                    }
                    return cell
                } else {
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: PolyTextFieldCell.reuseIdentifier,
                        for: indexPath
                    ) as! PolyTextFieldCell
                    cell.configure(label: field.label, value: field.getValue(record)) { [weak self] newValue in
                        guard let self else { return }
                        field.editAction?(record, newValue)
                        dataSource.save()
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

        private func relationshipCell(at indexPath: IndexPath, tableView: UITableView) -> UITableViewCell {
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
            let alert = UIAlertController(
                title: "Delete \(entity.displayName)?",
                message: "This action cannot be undone.",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.performDelete()
            })

            present(alert, animated: true)
        }

        private func performDelete() {
            Task {
                await dataSource.deleteRecord(record)
                dataSource.context.reloadData?()
                navigationController?.popViewController(animated: true)
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
            setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(label: String, value: String, action: ((String) -> Void)?) {
            self.label.text = label
            textField.text = value
            editAction = action
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            editAction?(textField.text ?? "")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        private func setupUI() {
            selectionStyle = .none

            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false

            textField.font = .systemFont(ofSize: 14)
            textField.borderStyle = .roundedRect
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.delegate = self

            contentView.addSubview(label)
            contentView.addSubview(textField)

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                textField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                textField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                textField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
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
            setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(label: String, value: String, action: ((String) -> Void)?) {
            self.label.text = label
            textView.text = value
            editAction = action
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            editAction?(textView.text)
        }

        private func setupUI() {
            selectionStyle = .none

            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false

            textView.font = .systemFont(ofSize: 14)
            textView.layer.borderColor = UIColor.separator.cgColor
            textView.layer.borderWidth = 0.5
            textView.layer.cornerRadius = 6
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.delegate = self

            contentView.addSubview(label)
            contentView.addSubview(textView)

            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                textView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
                textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
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
            setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(label: String, isOn: Bool, action: ((Bool) -> Void)?) {
            self.label.text = label
            toggle.isOn = isOn
            toggleAction = action
        }

        private func setupUI() {
            selectionStyle = .none

            label.font = .systemFont(ofSize: 14)
            label.translatesAutoresizingMaskIntoConstraints = false

            toggle.translatesAutoresizingMaskIntoConstraints = false
            toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)

            contentView.addSubview(label)
            contentView.addSubview(toggle)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

                toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }

        @objc private func toggleChanged() {
            toggleAction?(toggle.isOn)
        }
    }

#endif // os(iOS)
