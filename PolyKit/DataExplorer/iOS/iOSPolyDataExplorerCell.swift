//
//  iOSPolyDataExplorerCell.swift
//  by Danny Stewart
//  https://github.com/dannystewart/polykit-swift
//

#if os(iOS)

    import UIKit

    // MARK: - iOSPolyDataExplorerCell

    /// Table view cell for displaying entity records in the Data Explorer.
    public final class iOSPolyDataExplorerCell: UITableViewCell {
        public static let reuseIdentifier = "iOSPolyDataExplorerCell"

        private let titleLabel: UILabel = .init()
        private let subtitleLabel: UILabel = .init()
        private let detailLabel: UILabel = .init()
        private let badgeStack: UIStackView = .init()

        // MARK: Initialization

        override public init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            self.setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public func prepareForReuse() {
            super.prepareForReuse()
            self.titleLabel.textColor = .label
            self.titleLabel.text = nil
            self.subtitleLabel.text = nil
            self.detailLabel.text = nil
            self.badgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }

        // MARK: Configuration

        /// Configures the cell with record data from the entity.
        ///
        /// - Parameters:
        ///   - record: The record object.
        ///   - entity: The entity configuration.
        ///   - report: Optional integrity report for highlighting issues.
        public func configure(
            with record: AnyObject,
            entity: AnyPolyDataEntity,
            report: PolyDataIntegrityReport?,
        ) {
            // Use first 3 columns for title, subtitle, detail
            let columnCount = entity.columnCount

            if columnCount > 0 {
                self.titleLabel.text = entity.cellValue(record, 0)
                if let color = entity.cellColor(record, 0, report) {
                    self.titleLabel.textColor = color
                }
            }

            if columnCount > 1 {
                self.subtitleLabel.text = entity.cellValue(record, 1)
            }

            if columnCount > 2 {
                self.detailLabel.text = entity.cellValue(record, 2)
            }

            // Collect badges from all columns that define them
            for columnIndex in 0 ..< columnCount {
                if let badge = entity.cellBadge(record, columnIndex, report) {
                    self.addBadge(badge.text, color: badge.color)
                }
            }

            // Check for integrity issues (shown in addition to status badges)
            if let report {
                let recordID = entity.recordID(record)
                if report.hasIssue(entityID: entity.id, recordID: recordID) {
                    if let issueType = report.issueType(entityID: entity.id, recordID: recordID) {
                        self.addBadge("⚠️ \(issueType)", color: .systemRed)
                    }
                }
            }
        }

        /// Adds a badge with the given text and color.
        public func addBadge(_ text: String, color: UIColor) {
            let badge = UILabel()
            badge.text = text
            badge.font = .systemFont(ofSize: 9, weight: .medium)
            badge.textColor = color
            badge.backgroundColor = color.withAlphaComponent(0.15)
            badge.layer.cornerRadius = 4
            badge.layer.masksToBounds = true
            badge.textAlignment = .center

            let padding: CGFloat = 6
            badge.translatesAutoresizingMaskIntoConstraints = false

            let container = UIView()
            container.addSubview(badge)
            container.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                badge.topAnchor.constraint(equalTo: container.topAnchor),
                badge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                badge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            ])

            self.badgeStack.addArrangedSubview(container)
        }

        // MARK: Setup

        private func setupUI() {
            self.titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            self.titleLabel.translatesAutoresizingMaskIntoConstraints = false

            self.subtitleLabel.font = .systemFont(ofSize: 12)
            self.subtitleLabel.textColor = .secondaryLabel
            self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

            self.detailLabel.font = .systemFont(ofSize: 11)
            self.detailLabel.textColor = .tertiaryLabel
            self.detailLabel.numberOfLines = 2
            self.detailLabel.translatesAutoresizingMaskIntoConstraints = false

            self.badgeStack.axis = .horizontal
            self.badgeStack.spacing = 4
            self.badgeStack.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(self.titleLabel)
            contentView.addSubview(self.subtitleLabel)
            contentView.addSubview(self.detailLabel)
            contentView.addSubview(self.badgeStack)

            NSLayoutConstraint.activate([
                self.titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                self.titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.badgeStack.leadingAnchor, constant: -8),

                self.badgeStack.centerYAnchor.constraint(equalTo: self.titleLabel.centerYAnchor),
                self.badgeStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                self.subtitleLabel.topAnchor.constraint(equalTo: self.titleLabel.bottomAnchor, constant: 2),
                self.subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                self.detailLabel.topAnchor.constraint(equalTo: self.subtitleLabel.bottomAnchor, constant: 2),
                self.detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                self.detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                self.detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            ])

            accessoryType = .disclosureIndicator
        }
    }

#endif // os(iOS)
