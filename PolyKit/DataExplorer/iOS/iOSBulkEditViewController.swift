//
//  iOSBulkEditViewController.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(iOS)

    import UIKit

    // MARK: - iOSBulkEditViewController

    /// View controller for configuring and previewing bulk edit operations on iOS.
    @MainActor
    public final class iOSBulkEditViewController: UITableViewController {
        private let dataSource: PolyDataExplorerDataSource

        private var currentEntity: AnyPolyDataEntity?
        private var editableFields: [PolyDataField] = []
        private var allFields: [PolyDataField] = []

        private var selectedEntityIndex: Int = 0
        private var selectedTargetFieldIndex: Int = 0
        private var selectedWhereFieldIndex: Int = 0
        private var newValue: String = ""
        private var whereValue: String = ""
        private var incrementVersion: Bool = true

        private var errorMessage: String?

        // MARK: Initialization

        public init(dataSource: PolyDataExplorerDataSource) {
            self.dataSource = dataSource
            super.init(style: .insetGrouped)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public func viewDidLoad() {
            super.viewDidLoad()

            title = "Bulk Edit"
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(self.cancel))
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Preview", style: .done, target: self, action: #selector(self.preview))

            self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
            self.tableView.register(TextFieldCell.self, forCellReuseIdentifier: "textField")
            self.tableView.register(SwitchCell.self, forCellReuseIdentifier: "switch")
            self.tableView.register(ErrorCell.self, forCellReuseIdentifier: "error")

            // Initialize with current entity
            if let currentIndex = dataSource.configuration.entityIndex(withID: dataSource.currentEntity?.id ?? "") {
                self.selectedEntityIndex = currentIndex
            }
            self.updateCurrentEntity()
        }

        // MARK: Table View Data Source

        override public func numberOfSections(in _: UITableView) -> Int {
            self.errorMessage != nil ? 3 : 2
        }

        override public func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
            if self.errorMessage != nil {
                switch section {
                case 0: 1 // Error
                case 1: 5 // Fields
                case 2: 1 // Version checkbox
                default: 0
                }
            } else {
                switch section {
                case 0: 5 // Fields
                case 1: 1 // Version checkbox
                default: 0
                }
            }
        }

        override public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let errorOffset = self.errorMessage != nil ? 1 : 0

            // Error section
            if self.errorMessage != nil, indexPath.section == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "error", for: indexPath) as! ErrorCell
                cell.errorLabel.text = self.errorMessage
                return cell
            }

            // Fields section
            if indexPath.section == 0 + errorOffset {
                switch indexPath.row {
                case 0:
                    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
                    var config = cell.defaultContentConfiguration()
                    config.text = "Entity"
                    config.secondaryText = self.dataSource.configuration.entities[self.selectedEntityIndex].displayName
                    cell.contentConfiguration = config
                    cell.accessoryType = .disclosureIndicator
                    return cell

                case 1:
                    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
                    var config = cell.defaultContentConfiguration()
                    config.text = "Set field"
                    config.secondaryText = self.editableFields.isEmpty ? "Select entity first" : self.editableFields[self.selectedTargetFieldIndex].label
                    cell.contentConfiguration = config
                    cell.accessoryType = .disclosureIndicator
                    return cell

                case 2:
                    let cell = tableView.dequeueReusableCell(withIdentifier: "textField", for: indexPath) as! TextFieldCell
                    cell.label.text = "To value"
                    cell.textField.placeholder = "New value"
                    cell.textField.text = self.newValue
                    cell.onTextChanged = { [weak self] text in
                        self?.newValue = text
                    }
                    return cell

                case 3:
                    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
                    var config = cell.defaultContentConfiguration()
                    config.text = "Where field"
                    config.secondaryText = self.allFields.isEmpty ? "Select entity first" : self.allFields[self.selectedWhereFieldIndex].label
                    cell.contentConfiguration = config
                    cell.accessoryType = .disclosureIndicator
                    return cell

                case 4:
                    let cell = tableView.dequeueReusableCell(withIdentifier: "textField", for: indexPath) as! TextFieldCell
                    cell.label.text = "Equals"
                    cell.textField.placeholder = "Match value"
                    cell.textField.text = self.whereValue
                    cell.onTextChanged = { [weak self] text in
                        self?.whereValue = text
                    }
                    return cell

                default:
                    return UITableViewCell()
                }
            }

            // Version checkbox section
            if indexPath.section == 1 + errorOffset {
                let cell = tableView.dequeueReusableCell(withIdentifier: "switch", for: indexPath) as! SwitchCell
                cell.label.text = "Increment version (for PolyBase sync)"
                cell.switchControl.isOn = self.incrementVersion
                cell.onToggle = { [weak self] isOn in
                    self?.incrementVersion = isOn
                }
                return cell
            }

            return UITableViewCell()
        }

        override public func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
            let errorOffset = self.errorMessage != nil ? 1 : 0

            if self.errorMessage != nil, section == 0 {
                return nil
            }

            if section == 0 + errorOffset {
                return "Set a field to a new value for all records matching a condition"
            }

            return nil
        }

        override public func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
            let errorOffset = self.errorMessage != nil ? 1 : 0

            if section == 1 + errorOffset {
                return "Enable this if your app uses PolyBase for Supabase sync to automatically increment the version field for conflict resolution."
            }

            return nil
        }

        // MARK: Table View Delegate

        override public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)

            let errorOffset = self.errorMessage != nil ? 1 : 0

            guard indexPath.section == 0 + errorOffset else { return }

            switch indexPath.row {
            case 0:
                self.showEntityPicker()
            case 1:
                self.showTargetFieldPicker()
            case 3:
                self.showWhereFieldPicker()
            default:
                break
            }
        }

        @objc private func cancel() {
            dismiss(animated: true)
        }

        @objc private func preview() {
            self.errorMessage = nil
            self.tableView.reloadData()

            // Build operation
            guard let entity = currentEntity else { return }
            guard !self.editableFields.isEmpty, !self.allFields.isEmpty else {
                self.showError("No editable fields available for this entity")
                return
            }

            let operation = BulkEditOperation(
                entityID: entity.id,
                targetField: self.editableFields[self.selectedTargetFieldIndex],
                newValue: self.newValue,
                whereField: self.allFields[self.selectedWhereFieldIndex],
                whereValue: self.whereValue,
                incrementVersion: self.incrementVersion,
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

            // Show preview
            let previewVC = iOSBulkEditPreviewViewController(
                dataSource: dataSource,
                operation: operation,
                preview: preview,
            )
            navigationController?.pushViewController(previewVC, animated: true)
        }

        private func showError(_ message: String) {
            self.errorMessage = message
            self.tableView.reloadData()
            self.tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
        }

        // MARK: Pickers

        private func showEntityPicker() {
            let alert = UIAlertController(title: "Select Entity", message: nil, preferredStyle: .actionSheet)

            for (index, entity) in self.dataSource.configuration.entities.enumerated() {
                alert.addAction(UIAlertAction(title: entity.displayName, style: .default) { [weak self] _ in
                    self?.selectedEntityIndex = index
                    self?.updateCurrentEntity()
                    self?.errorMessage = nil
                    self?.tableView.reloadData()
                })
            }

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.tableView
                popover.sourceRect = self.tableView.rectForRow(at: IndexPath(row: 0, section: self.errorMessage != nil ? 1 : 0))
            }

            present(alert, animated: true)
        }

        private func showTargetFieldPicker() {
            guard !self.editableFields.isEmpty else { return }

            let alert = UIAlertController(title: "Set Field", message: nil, preferredStyle: .actionSheet)

            for (index, field) in self.editableFields.enumerated() {
                alert.addAction(UIAlertAction(title: field.label, style: .default) { [weak self] _ in
                    self?.selectedTargetFieldIndex = index
                    self?.errorMessage = nil
                    self?.tableView.reloadData()
                })
            }

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.tableView
                popover.sourceRect = self.tableView.rectForRow(at: IndexPath(row: 1, section: self.errorMessage != nil ? 1 : 0))
            }

            present(alert, animated: true)
        }

        private func showWhereFieldPicker() {
            guard !self.allFields.isEmpty else { return }

            let alert = UIAlertController(title: "Where Field", message: nil, preferredStyle: .actionSheet)

            for (index, field) in self.allFields.enumerated() {
                alert.addAction(UIAlertAction(title: field.label, style: .default) { [weak self] _ in
                    self?.selectedWhereFieldIndex = index
                    self?.errorMessage = nil
                    self?.tableView.reloadData()
                })
            }

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.tableView
                popover.sourceRect = self.tableView.rectForRow(at: IndexPath(row: 3, section: self.errorMessage != nil ? 1 : 0))
            }

            present(alert, animated: true)
        }

        private func updateCurrentEntity() {
            guard self.selectedEntityIndex < self.dataSource.configuration.entities.count else { return }
            self.currentEntity = self.dataSource.configuration.entities[self.selectedEntityIndex]

            guard let entity = currentEntity else { return }

            self.allFields = entity.detailFields.filter { !$0.isToggle }
            self.editableFields = self.allFields.filter(\.isEditable)

            self.selectedTargetFieldIndex = 0
            self.selectedWhereFieldIndex = 0
        }
    }

    // MARK: - TextFieldCell

    private final class TextFieldCell: UITableViewCell {
        let label: UILabel = .init()
        let textField: UITextField = .init()
        var onTextChanged: ((String) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupUI() {
            self.label.translatesAutoresizingMaskIntoConstraints = false
            self.label.font = .systemFont(ofSize: 15)
            self.label.textColor = .label
            self.label.setContentHuggingPriority(.required, for: .horizontal)

            self.textField.translatesAutoresizingMaskIntoConstraints = false
            self.textField.font = .systemFont(ofSize: 15)
            self.textField.textAlignment = .right
            self.textField.returnKeyType = .done
            self.textField.delegate = self
            self.textField.addTarget(self, action: #selector(self.textChanged), for: .editingChanged)

            contentView.addSubview(self.label)
            contentView.addSubview(self.textField)

            NSLayoutConstraint.activate([
                self.label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

                self.textField.leadingAnchor.constraint(equalTo: self.label.trailingAnchor, constant: 12),
                self.textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                self.textField.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }

        @objc private func textChanged() {
            self.onTextChanged?(self.textField.text ?? "")
        }
    }

    extension TextFieldCell: UITextFieldDelegate {
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }

    // MARK: - SwitchCell

    private final class SwitchCell: UITableViewCell {
        let label: UILabel = .init()
        let switchControl: UISwitch = .init()
        var onToggle: ((Bool) -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupUI() {
            self.label.translatesAutoresizingMaskIntoConstraints = false
            self.label.font = .systemFont(ofSize: 15)
            self.label.textColor = .label
            self.label.numberOfLines = 0

            self.switchControl.translatesAutoresizingMaskIntoConstraints = false
            self.switchControl.addTarget(self, action: #selector(self.switched), for: .valueChanged)

            contentView.addSubview(self.label)
            contentView.addSubview(self.switchControl)

            NSLayoutConstraint.activate([
                self.label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.label.trailingAnchor.constraint(equalTo: self.switchControl.leadingAnchor, constant: -12),
                self.label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

                self.switchControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                self.switchControl.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }

        @objc private func switched() {
            self.onToggle?(self.switchControl.isOn)
        }
    }

    // MARK: - ErrorCell

    private final class ErrorCell: UITableViewCell {
        let errorLabel: UILabel = .init()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupUI() {
            backgroundColor = .systemRed.withAlphaComponent(0.1)

            self.errorLabel.translatesAutoresizingMaskIntoConstraints = false
            self.errorLabel.font = .systemFont(ofSize: 13, weight: .medium)
            self.errorLabel.textColor = .systemRed
            self.errorLabel.numberOfLines = 0

            contentView.addSubview(self.errorLabel)

            NSLayoutConstraint.activate([
                self.errorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
                self.errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                self.errorLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            ])
        }
    }

    // MARK: - iOSBulkEditPreviewViewController

    /// Preview view showing affected records and allowing final confirmation.
    @MainActor
    final class iOSBulkEditPreviewViewController: UITableViewController {
        private let dataSource: PolyDataExplorerDataSource
        private let operation: BulkEditOperation
        private let preview: BulkEditPreview

        // MARK: Initialization

        init(dataSource: PolyDataExplorerDataSource, operation: BulkEditOperation, preview: BulkEditPreview) {
            self.dataSource = dataSource
            self.operation = operation
            self.preview = preview
            super.init(style: .insetGrouped)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()

            title = "Confirm Bulk Edit"
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Apply", style: .done, target: self, action: #selector(self.apply))

            self.tableView.register(PreviewCell.self, forCellReuseIdentifier: "preview")
        }

        // MARK: Table View Data Source

        override func numberOfSections(in _: UITableView) -> Int {
            1
        }

        override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
            self.preview.matchingRecords.count
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "preview", for: indexPath) as! PreviewCell
            let record = self.preview.matchingRecords[indexPath.row]

            cell.recordLabel.text = record.displayName
            cell.currentLabel.text = "Current: \(record.currentValue)"
            cell.newLabel.text = "New: \(record.newValue)"

            return cell
        }

        override func tableView(_: UITableView, titleForHeaderInSection _: Int) -> String? {
            if self.preview.hasMore {
                "Showing first 5 of \(self.preview.totalCount) matching records. All \(self.preview.totalCount) will be updated."
            } else {
                "\(self.preview.totalCount) record(s) will be updated:"
            }
        }

        @objc private func apply() {
            navigationItem.rightBarButtonItem?.isEnabled = false

            // Show progress
            let hud = UIActivityIndicatorView(style: .medium)
            hud.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: hud)

            Task {
                let executor = BulkEditExecutor(dataSource: dataSource)
                let result = await executor.execute(preview: self.preview, operation: self.operation)

                if result.isSuccess {
                    self.dataSource.context.reloadData?()

                    let alert = UIAlertController(
                        title: "Bulk Edit Complete",
                        message: "Successfully updated \(result.updatedCount) record(s).",
                        preferredStyle: .alert,
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                        self?.navigationController?.popToRootViewController(animated: true)
                    })
                    present(alert, animated: true)
                } else {
                    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Apply", style: .done, target: self, action: #selector(self.apply))

                    let alert = UIAlertController(
                        title: "Bulk Edit Failed",
                        message: result.error ?? "Unknown error",
                        preferredStyle: .alert,
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    present(alert, animated: true)
                }
            }
        }
    }

    // MARK: - PreviewCell

    private final class PreviewCell: UITableViewCell {
        let recordLabel: UILabel = .init()
        let currentLabel: UILabel = .init()
        let newLabel: UILabel = .init()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupUI() {
            let stack = UIStackView(arrangedSubviews: [recordLabel, currentLabel, newLabel])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .vertical
            stack.spacing = 4

            self.recordLabel.font = .systemFont(ofSize: 15, weight: .medium)
            self.recordLabel.textColor = .label

            self.currentLabel.font = .systemFont(ofSize: 13)
            self.currentLabel.textColor = .secondaryLabel

            self.newLabel.font = .systemFont(ofSize: 13)
            self.newLabel.textColor = .systemBlue

            contentView.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            ])
        }
    }

#endif // os(iOS)
