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
            setupUI()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override public func prepareForReuse() {
            super.prepareForReuse()
            titleLabel.textColor = .label
            titleLabel.text = nil
            subtitleLabel.text = nil
            detailLabel.text = nil
            badgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
            report: PolyDataIntegrityReport?
        ) {
            // Use first 3 columns for title, subtitle, detail
            let columnCount = entity.columnCount

            if columnCount > 0 {
                titleLabel.text = entity.cellValue(record, 0)
                if let color = entity.cellColor(record, 0, report) {
                    titleLabel.textColor = color
                }
            }

            if columnCount > 1 {
                subtitleLabel.text = entity.cellValue(record, 1)
            }

            if columnCount > 2 {
                detailLabel.text = entity.cellValue(record, 2)
            }

            // Check for integrity issues
            if let report {
                let recordID = entity.recordID(record)
                if report.hasIssue(entityID: entity.id, recordID: recordID) {
                    if let issueType = report.issueType(entityID: entity.id, recordID: recordID) {
                        addBadge("⚠️ \(issueType)", color: .systemRed)
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

            badgeStack.addArrangedSubview(container)
        }

        // MARK: Setup

        private func setupUI() {
            titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            subtitleLabel.font = .systemFont(ofSize: 12)
            subtitleLabel.textColor = .secondaryLabel
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .tertiaryLabel
            detailLabel.numberOfLines = 2
            detailLabel.translatesAutoresizingMaskIntoConstraints = false

            badgeStack.axis = .horizontal
            badgeStack.spacing = 4
            badgeStack.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(titleLabel)
            contentView.addSubview(subtitleLabel)
            contentView.addSubview(detailLabel)
            contentView.addSubview(badgeStack)

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeStack.leadingAnchor, constant: -8),

                badgeStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                badgeStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

                detailLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 2),
                detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            ])

            accessoryType = .disclosureIndicator
        }
    }

#endif // os(iOS)
