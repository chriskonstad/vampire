import SwiftUI
import UIKit

import CullIntent

/// The shoot grid. UIKit `UICollectionView` rather than SwiftUI Grid because
/// scroll perf depends on `UICollectionViewDataSourcePrefetching` driving
/// the image provider's caching (hard constraint: smoothness).
struct GridView: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    @Binding var pagerIndex: Int?
    /// Passed in as a stored property so SwiftUI reliably re-invokes
    /// updateUIViewController when verdicts change — the model's plain-class
    /// IntentLog is invisible to observation.
    let revision: Int
    /// Camera sessions: thumbnails arrive after the grid first draws.
    let imageRevision: Int

    func makeUIViewController(context: Context) -> GridViewController {
        GridViewController(model: model) { index in
            pagerIndex = index
        }
    }

    func updateUIViewController(_ controller: GridViewController, context: Context) {
        controller.reload(items: model.items, revision: revision, imageRevision: imageRevision)
    }
}

final class GridViewController: UIViewController {
    private let model: AppModel
    private let onTap: (Int) -> Void

    private var items: [CullItem] = []
    private var lastRevision = -1
    private var lastImageRevision = -1
    private var collectionView: UICollectionView!
    private var thumbnailSize = CGSize(width: 200, height: 200)

    init(model: AppModel, onTap: @escaping (Int) -> Void) {
        self.model = model
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(ThumbCell.self, forCellWithReuseIdentifier: ThumbCell.reuseID)
        view.addSubview(collectionView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Columns follow width: ~100pt tiles, at least 4 — so landscape and
        // big canvases (iPhone Duo unfolded: 6) get a wider sweep, same size.
        let columns: CGFloat = max(4, (view.bounds.width / 100).rounded(.down))
        let layout = collectionView.collectionViewLayout as! UICollectionViewFlowLayout
        let side = (view.bounds.width - (columns - 1) * 2) / columns
        layout.itemSize = CGSize(width: side, height: side)
        let scale = traitCollection.displayScale  // per-screen (Duo folds between two)
        thumbnailSize = CGSize(width: side * scale, height: side * scale)
    }

    func reload(items: [CullItem], revision: Int, imageRevision: Int) {
        let itemsChanged = items.map(\.id) != self.items.map(\.id)
        let imagesChanged = imageRevision != lastImageRevision
        guard itemsChanged || revision != lastRevision || imagesChanged else { return }
        lastRevision = revision
        lastImageRevision = imageRevision
        if itemsChanged {
            self.items = items
            model.imageProvider.stopCachingAll()
            collectionView?.reloadData()
        } else {
            // Verdict/index change: refresh visible badges (and, for camera
            // sessions, thumbnails that just arrived) — no relayout churn.
            for indexPath in collectionView?.indexPathsForVisibleItems ?? [] {
                if let cell = collectionView.cellForItem(at: indexPath) as? ThumbCell {
                    configureBadges(cell, item: self.items[indexPath.item])
                    if imagesChanged { loadImage(into: cell, item: self.items[indexPath.item]) }
                }
            }
        }
    }

    private func loadImage(into cell: ThumbCell, item: CullItem) {
        model.imageProvider.requestThumbnail(for: item, targetSize: thumbnailSize) { image in
            // Cell may have been reused for another item by delivery time.
            if cell.representedAssetID == item.id, let image {
                cell.imageView.image = image
            }
        }
    }

    private func configureBadges(_ cell: ThumbCell, item: CullItem) {
        cell.verdict = model.verdict(for: item)
        let record = model.index[item.id]
        cell.showsAFBadge = record?.focusLocation != nil
        cell.faceCount = record?.faceCount ?? 0
        cell.isBurstLeader = model.burstGroups
            .first { $0.id == item.id && $0.count > 1 } != nil
        cell.score = record?.aestheticScore100
        cell.warnsClosedEyes = (record?.closedEyesCount ?? 0) > 0
        cell.warnsExposure = (record?.clippedHighlights ?? 0) > 0.03
            || (record?.crushedShadows ?? 0) > 0.12
        cell.isUtility = record?.isUtility ?? false
    }
}

extension GridViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ThumbCell.reuseID, for: indexPath
        ) as! ThumbCell
        let item = items[indexPath.item]
        cell.representedAssetID = item.id
        configureBadges(cell, item: item)
        loadImage(into: cell, item: item)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onTap(indexPath.item)
    }
}

extension GridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        model.imageProvider.startCaching(indexPaths.map { items[$0.item] }, targetSize: thumbnailSize)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        model.imageProvider.stopCaching(indexPaths.map { items[$0.item] }, targetSize: thumbnailSize)
    }
}

final class ThumbCell: UICollectionViewCell {
    static let reuseID = "ThumbCell"

    let imageView = UIImageView()
    private let badgeStack = UIStackView()
    /// Verdict marker: a solid dot in the top-right corner — readable at a
    /// glance across a 4-column grid, where SF-symbol glyphs got lost.
    private let verdictDot = UIView()

    var representedAssetID: String?

    var verdict: Verdict? {
        didSet {
            switch verdict {
            case .keep:
                verdictDot.isHidden = false
                verdictDot.backgroundColor = .systemGreen
                imageView.alpha = 1
            case .reject:
                verdictDot.isHidden = false
                verdictDot.backgroundColor = .systemRed
                imageView.alpha = 0.35 // rejected frames recede
            case .maybe:
                verdictDot.isHidden = false
                verdictDot.backgroundColor = .systemYellow
                imageView.alpha = 1
            case nil:
                verdictDot.isHidden = true
                imageView.alpha = 1
            }
        }
    }

    var showsAFBadge = false { didSet { afBadge.isHidden = !showsAFBadge } }
    var faceCount = 0 {
        didSet {
            faceBadge.isHidden = faceCount == 0
            faceBadge.text = faceCount > 1 ? "☺︎\(faceCount)" : "☺︎"
        }
    }
    var isBurstLeader = false { didSet { burstBadge.isHidden = !isBurstLeader } }

    /// Aesthetic 0–100; tiered color so quality skims at a glance.
    var score: Int? {
        didSet {
            scoreChip.isHidden = score == nil
            if let score {
                scoreChip.text = "★\(score)"
                scoreChip.textColor = score >= 70 ? .systemYellow
                    : score >= 45 ? .white : .systemGray2
            }
        }
    }
    var warnsClosedEyes = false { didSet { eyesWarning.isHidden = !warnsClosedEyes } }
    var warnsExposure = false { didSet { exposureWarning.isHidden = !warnsExposure } }
    var isUtility = false { didSet { utilityBadge.isHidden = !isUtility } }

    private let afBadge = UILabel()
    private let faceBadge = UILabel()
    private let burstBadge = UILabel()
    private let scoreChip = UILabel()
    private let eyesWarning = UIImageView()
    private let exposureWarning = UIImageView()
    private let utilityBadge = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        for (badge, text) in [(afBadge, "AF"), (faceBadge, "☺︎"), (burstBadge, "burst")] {
            badge.text = text
            badge.font = .systemFont(ofSize: 9, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            badge.isHidden = true
        }
        badgeStack.axis = .horizontal
        badgeStack.spacing = 3
        [afBadge, faceBadge, burstBadge].forEach(badgeStack.addArrangedSubview)
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badgeStack)

        verdictDot.translatesAutoresizingMaskIntoConstraints = false
        verdictDot.layer.cornerRadius = 6
        verdictDot.layer.borderWidth = 1.5
        verdictDot.layer.borderColor = UIColor.white.cgColor
        verdictDot.isHidden = true
        contentView.addSubview(verdictDot)

        // HUD: aesthetic score (top-left) + warning icons (bottom-right).
        scoreChip.font = .systemFont(ofSize: 10, weight: .bold)
        scoreChip.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        scoreChip.layer.cornerRadius = 4
        scoreChip.layer.masksToBounds = true
        scoreChip.textAlignment = .center
        scoreChip.isHidden = true
        scoreChip.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scoreChip)

        let warningConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        eyesWarning.image = UIImage(systemName: "eye.slash.fill", withConfiguration: warningConfig)
        eyesWarning.tintColor = .systemRed
        exposureWarning.image = UIImage(systemName: "exclamationmark.triangle.fill", withConfiguration: warningConfig)
        exposureWarning.tintColor = .systemYellow
        utilityBadge.image = UIImage(systemName: "doc.text.fill", withConfiguration: warningConfig)
        utilityBadge.tintColor = .systemGray2

        let warningStack = UIStackView(arrangedSubviews: [utilityBadge, exposureWarning, eyesWarning])
        warningStack.axis = .horizontal
        warningStack.spacing = 3
        [eyesWarning, exposureWarning, utilityBadge].forEach { $0.isHidden = true }
        warningStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(warningStack)

        NSLayoutConstraint.activate([
            badgeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 3),
            badgeStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            verdictDot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            verdictDot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            verdictDot.widthAnchor.constraint(equalToConstant: 12),
            verdictDot.heightAnchor.constraint(equalToConstant: 12),
            scoreChip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 3),
            scoreChip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            scoreChip.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            scoreChip.heightAnchor.constraint(equalToConstant: 14),
            warningStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            warningStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        representedAssetID = nil
        verdict = nil
        showsAFBadge = false
        faceCount = 0
        isBurstLeader = false
        score = nil
        warnsClosedEyes = false
        warnsExposure = false
        isUtility = false
    }
}
