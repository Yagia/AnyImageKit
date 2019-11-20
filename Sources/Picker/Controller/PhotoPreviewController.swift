//
//  PhotoPreviewController.swift
//  AnyImageKit
//
//  Created by 蒋惠 on 2019/9/17.
//  Copyright © 2019 AnyImageProject.org. All rights reserved.
//

import UIKit
import Photos

protocol PhotoPreviewControllerDataSource: class {
    
    typealias PreviewData = (thumbnail: UIImage?, asset: Asset)
    
    /// 获取需要展示图片的数量
    func numberOfPhotos(in controller: PhotoPreviewController) -> Int
    
    /// 获取索引对应的数据模型
    func previewController(_ controller: PhotoPreviewController, assetOfIndex index: Int) -> PreviewData
    
    /// 获取转场动画时的缩略图所在的 view
    func previewController(_ controller: PhotoPreviewController, thumbnailViewForIndex index: Int) -> UIView?
}

protocol PhotoPreviewControllerDelegate: class {
    
    /// 选择一张图片，需要返回所选图片的序号
    func previewController(_ controller: PhotoPreviewController, didSelected index: Int)
    
    /// 取消选择一张图片
    func previewController(_ controller: PhotoPreviewController, didDeselected index: Int)
    
    /// 开启/关闭原图
    func previewController(_ controller: PhotoPreviewController, useOriginalImage: Bool)
    
    /// 点击返回
    func previewControllerDidClickBack(_ controller: PhotoPreviewController)
    
    /// 点击完成
    func previewControllerDidClickDone(_ controller: PhotoPreviewController)
    
    /// 即将消失
    func previewControllerWillDisappear(_ controller: PhotoPreviewController)
}

extension PhotoPreviewControllerDelegate {
    func previewController(_ controller: PhotoPreviewController, didSelected index: Int) { }
    func previewController(_ controller: PhotoPreviewController, didDeselected index: Int) { }
    func previewController(_ controller: PhotoPreviewController, useOriginalImage: Bool) { }
    func previewControllerDidClickBack(_ controller: PhotoPreviewController) { }
    func previewControllerDidClickDone(_ controller: PhotoPreviewController) { }
}


final class PhotoPreviewController: UIViewController {
    
    weak var delegate: PhotoPreviewControllerDelegate? = nil
    weak var dataSource: PhotoPreviewControllerDataSource? = nil
    
    /// 图片索引
    var currentIndex: Int = 0 {
        didSet {
            didSetCurrentIdx()
        }
    }
    /// 左右两张图之间的间隙
    var photoSpacing: CGFloat = 30
    /// 图片缩放模式
    var imageScaleMode: UIView.ContentMode = .scaleAspectFill
    /// 捏合手势放大图片时的最大允许比例
    var imageMaximumZoomScale: CGFloat = 2.0
    /// 双击放大图片时的目标比例
    var imageZoomScaleForDoubleTap: CGFloat = 2.0
    
    // MARK: - Private
    
    /// 当前正在显示视图的前一个页面关联视图
    private var relatedView: UIView? {
        return dataSource?.previewController(self, thumbnailViewForIndex: currentIndex)
    }
    /// 缩放型转场协调器
    private weak var scalePresentationController: ScalePresentationController?
    /// ToolBar 缩放动画前的状态
    private var toolBarHiddenStateBeforePan = false
    
    private lazy var flowLayout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        return layout
    }()
    private(set) lazy var collectionView: UICollectionView = { [unowned self] in
        let collectionView = UICollectionView(frame: CGRect.zero, collectionViewLayout: flowLayout)
        collectionView.backgroundColor = UIColor.clear
        collectionView.decelerationRate = UIScrollView.DecelerationRate.fast
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.registerCell(PhotoPreviewCell.self)
        collectionView.registerCell(PhotoGIFPreviewCell.self)
        collectionView.registerCell(VideoPreviewCell.self)
        collectionView.registerCell(PhotoLivePreviewCell.self)
        collectionView.isPagingEnabled = true
        collectionView.alwaysBounceHorizontal = false
        collectionView.isPrefetchingEnabled = false
        return collectionView
        }()
    private(set) lazy var navigationBar: PickerPreviewNavigationBar = {
        let view = PickerPreviewNavigationBar()
        view.backButton.addTarget(self, action: #selector(backButtonTapped(_:)), for: .touchUpInside)
        view.selectButton.addTarget(self, action: #selector(selectButtonTapped(_:)), for: .touchUpInside)
        return view
    }()
    private lazy var toolBar: PickerToolBar = {
        let view = PickerToolBar(style: .preview)
        view.originalButton.isHidden = !PickerManager.shared.config.allowUseOriginalImage
        view.originalButton.isSelected = PickerManager.shared.useOriginalImage
        view.leftButton.isHidden = true
        #if ANYIMAGEKIT_ENABLE_EDITOR
        view.leftButton.addTarget(self, action: #selector(editButtonTapped(_:)), for: .touchUpInside)
        #endif
        view.originalButton.addTarget(self, action: #selector(originalImageButtonTapped(_:)), for: .touchUpInside)
        view.doneButton.addTarget(self, action: #selector(doneButtonTapped(_:)), for: .touchUpInside)
        return view
    }()
    private lazy var indexView: PickerPreviewIndexView = {
        let view = PickerPreviewIndexView()
        view.isHidden = true
        view.delegate = self
        return view
    }()
    
    init() {
        super.init(nibName: nil, bundle: nil)
        transitioningDelegate = self
        modalPresentationStyle = .custom
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        addNotification()
        setupViews()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didSetCurrentIdx()
        setGIF(animated: true)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setBar(hidden: false, animated: true)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayout()
    }
    
    @available(iOS 11.0, *)
    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
    
    deinit {
        for cell in collectionView.visibleCells {
            if let cell = cell as? PreviewCell, !cell.asset.isSelected {
                PickerManager.shared.cancelFetch(for: cell.asset.phAsset.localIdentifier)
            }
        }
    }
}

// MARK: - Private function
extension PhotoPreviewController {
    
    private func addNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(containerSizeDidChange(_:)), name: .containerSizeDidChange, object: nil)
    }
    
    /// 添加视图
    private func setupViews() {
        view.backgroundColor = UIColor.clear
        if #available(iOS 11.0, *) {
            collectionView.contentInsetAdjustmentBehavior = .never
        }
        view.addSubview(collectionView)
        view.addSubview(navigationBar)
        view.addSubview(toolBar)
        view.addSubview(indexView)
        setupLayout()
        setBar(hidden: true, animated: false, isNormal: false)
    }
    
    /// 设置视图布局
    private func setupLayout() {
        navigationBar.snp.makeConstraints { maker in
            maker.top.equalToSuperview()
            maker.left.right.equalToSuperview()
            if #available(iOS 11, *) {
                maker.bottom.equalTo(view.safeAreaLayoutGuide.snp.top).offset(44)
            } else {
                maker.bottom.equalTo(topLayoutGuide.snp.bottom).offset(44)
            }
        }
        toolBar.snp.makeConstraints { maker in
            maker.left.right.bottom.equalToSuperview()
            if #available(iOS 11, *) {
                maker.top.equalTo(view.safeAreaLayoutGuide.snp.bottom).offset(-56)
            } else {
                maker.top.equalTo(bottomLayoutGuide.snp.top).offset(-56)
            }
        }
        indexView.snp.makeConstraints { maker in
            maker.left.right.equalToSuperview()
            maker.bottom.equalTo(toolBar.snp.top)
            maker.height.equalTo(96)
        }
    }
    
    /// 更新视图布局
    private func updateLayout() {
        flowLayout.minimumLineSpacing = photoSpacing
        flowLayout.itemSize = ScreenHelper.mainBounds.size
        collectionView.frame = ScreenHelper.mainBounds
        collectionView.frame.size.width = ScreenHelper.mainBounds.width + photoSpacing
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: photoSpacing)
    }
    
    /// 显示/隐藏工具栏
    private func setBar(hidden: Bool, animated: Bool = true, isNormal: Bool = true) {
        if navigationBar.alpha == 0 && hidden { return }
        if navigationBar.alpha == 1 && !hidden { return }
        if isNormal {
            NotificationCenter.default.post(name: .setupStatusBarHidden, object: hidden)
            scalePresentationController?.maskView.backgroundColor = hidden ? UIColor.black : ColorHelper.createByStyle(light: .white, dark: .black)
        }
        
        if animated {
            UIView.animate(withDuration: 0.25) {
                self.navigationBar.alpha = hidden ? 0 : 1
                self.toolBar.alpha = hidden ? 0 : 1
                self.indexView.alpha = hidden ? 0 : 1
            }
        } else {
            navigationBar.alpha = hidden ? 0 : 1
            toolBar.alpha = hidden ? 0 : 1
            indexView.alpha = hidden ? 0 : 1
        }
    }
    
    private func didSetCurrentIdx() {
        guard let data = dataSource?.previewController(self, assetOfIndex: currentIndex) else { return }
        navigationBar.selectButton.isEnabled = true
        navigationBar.selectButton.setNum(data.asset.selectedNum, isSelected: data.asset.isSelected, animated: false)
        indexView.currentIndex = currentIndex
        
        if PickerManager.shared.config.allowUseOriginalImage {
            toolBar.originalButton.isHidden = data.asset.phAsset.mediaType != .image
        }
        #if ANYIMAGEKIT_ENABLE_EDITOR
        switch PickerManager.shared.editorConfig.options {
        case .photo:
            toolBar.leftButton.isHidden = data.asset.phAsset.mediaType != .image
        default:
            break
        }
        #endif
    }
    
    /// 播放/暂停 GIF
    /// - Parameter animated: true-播放；false-暂停
    private func setGIF(animated: Bool) {
        for cell in collectionView.visibleCells {
            if let cell = cell as? PhotoGIFPreviewCell {
                if animated {
                    cell.imageView.startAnimating()
                } else {
                    cell.imageView.stopAnimating()
                }
            }
        }
    }
    
    /// 暂停视频
    private func stopVideo() {
        for cell in collectionView.visibleCells {
            if let cell = cell as? VideoPreviewCell {
                cell.pause()
            }
        }
    }
}

// MARK: - Target
extension PhotoPreviewController {
    
    @objc private func containerSizeDidChange(_ sender: Notification) {
        collectionView.reloadData()
        let indexPath = IndexPath(item: currentIndex, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
    }
    
    /// NavigationBar - Back
    @objc private func backButtonTapped(_ sender: UIButton) {
        delegate?.previewControllerWillDisappear(self)
        dismiss(animated: true, completion: nil)
        NotificationCenter.default.post(name: .setupStatusBarHidden, object: false)
    }
    
    /// NavigationBar - Select
    @objc func selectButtonTapped(_ sender: NumberCircleButton) {
        guard let data = dataSource?.previewController(self, assetOfIndex: currentIndex) else { return }
        if !data.asset.isSelected && PickerManager.shared.isUpToLimit {
            let message = String(format: BundleHelper.pickerLocalizedString(key: "Select a maximum of %zd photos"), PickerManager.shared.config.selectLimit)
            let alert = UIAlertController(title: BundleHelper.pickerLocalizedString(key: "Alert"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: BundleHelper.pickerLocalizedString(key: "OK"), style: .default, handler: nil))
            present(alert, animated: true, completion: nil)
            return
        }
        
        data.asset.isSelected = !sender.isSelected
        if data.asset.isSelected {
            PickerManager.shared.addSelectedAsset(data.asset)
        } else {
            PickerManager.shared.removeSelectedAsset(data.asset)
        }
        navigationBar.selectButton.setNum(data.asset.selectedNum, isSelected: data.asset.isSelected, animated: true)
        
        if data.asset.isSelected {
            delegate?.previewController(self, didSelected: currentIndex)
        } else {
            delegate?.previewController(self, didDeselected: currentIndex)
        }
        indexView.didChangeSelectedAsset()
    }
    
    /// ToolBar - Original
    @objc private func originalImageButtonTapped(_ sender: OriginalButton) {
        let manager = PickerManager.shared
        manager.useOriginalImage = sender.isSelected
        delegate?.previewController(self, useOriginalImage: sender.isSelected)
        
        // 选择当前照片
        if manager.useOriginalImage && !manager.isUpToLimit {
            guard let data = dataSource?.previewController(self, assetOfIndex: currentIndex) else { return }
            if !data.asset.isSelected {
                selectButtonTapped(navigationBar.selectButton)
            }
        }
    }
    
    /// ToolBar - Done
    @objc private func doneButtonTapped(_ sender: UIButton) {
        delegate?.previewControllerWillDisappear(self)
        delegate?.previewControllerDidClickDone(self)
    }
}

// MARK: - UICollectionViewDataSource
extension PhotoPreviewController: UICollectionViewDataSource {
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return dataSource?.numberOfPhotos(in: self) ?? 0
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let data = dataSource?.previewController(self, assetOfIndex: indexPath.row) else { return UICollectionViewCell() }
        let cell: PreviewCell
        switch data.asset.mediaType {
        case .photo:
            let photoCell = collectionView.dequeueReusableCell(PhotoPreviewCell.self, for: indexPath)
            photoCell.imageView.contentMode = imageScaleMode
            photoCell.imageMaximumZoomScale = imageMaximumZoomScale
            photoCell.imageZoomScaleForDoubleTap = imageZoomScaleForDoubleTap
            cell = photoCell
        case .video:
            cell = collectionView.dequeueReusableCell(VideoPreviewCell.self, for: indexPath)
            cell.imageView.contentMode = imageScaleMode
        case .photoGIF:
            cell = collectionView.dequeueReusableCell(PhotoGIFPreviewCell.self, for: indexPath)
        case .photoLive:
            cell = collectionView.dequeueReusableCell(PhotoLivePreviewCell.self, for: indexPath)
            cell.imageView.contentMode = imageScaleMode
        }
        cell.delegate = self
        cell.asset = data.asset
        return cell
    }
}

// MARK: - UICollectionViewDelegate
extension PhotoPreviewController: UICollectionViewDelegate {
    
    /// Cell 进入屏幕 - 请求数据
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let data = dataSource?.previewController(self, assetOfIndex: indexPath.row) else { return }
        switch cell {
        case let cell as PhotoPreviewCell:
            if data.asset._image != nil {
                cell.setImage(data.asset._image)
            } else {
                if let originalImage = PickerManager.shared.readCache(for: data.asset.phAsset.localIdentifier) {
                    cell.setImage(originalImage)
                } else {
                    cell.setImage(data.thumbnail)
                    cell.requestPhoto()
                }
            }
        case let cell as VideoPreviewCell:
            if let originalImage = PickerManager.shared.readCache(for: data.asset.phAsset.localIdentifier) {
                cell.setImage(originalImage)
            } else {
                cell.setImage(data.thumbnail)
                cell.requestPhoto()
            }
            cell.requestVideo()
        case let cell as PhotoGIFPreviewCell:
            cell.requestGIF()
        case let cell as PhotoLivePreviewCell:
            cell.setImage(data.thumbnail)
            cell.requestLivePhoto()
        default:
            break
        }
    }
    
    /// Cell 离开屏幕 - 重设状态
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        switch cell {
        case let cell as PreviewCell:
            cell.reset()
            if !cell.asset.isSelected {
                PickerManager.shared.cancelFetch(for: cell.asset.phAsset.localIdentifier)
            }
        default:
            break
        }
    }
}

// MARK: - UIScrollViewDelegate
extension PhotoPreviewController: UIScrollViewDelegate {
    
    /// 开始滑动 - 停止 GIF 和视频
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setGIF(animated: false)
        stopVideo()
    }
    
    /// 停止滑动 - 开始 GIF
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setGIF(animated: true)
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentSize.width - scrollView.contentOffset.x < scrollView.bounds.width { return } // isLast
        var idx = Int(scrollView.contentOffset.x / scrollView.bounds.width)
        let x = scrollView.contentOffset.x.truncatingRemainder(dividingBy: scrollView.bounds.width)
        if x > scrollView.bounds.width / 2 {
            idx += 1
        }
        if idx != currentIndex {
            currentIndex = idx
        }
    }
}

// MARK: - PreviewCellDelegate
extension PhotoPreviewController: PreviewCellDelegate {
    
    func previewCellDidBeginPan(_ cell: PreviewCell) {
        delegate?.previewControllerWillDisappear(self)
        toolBarHiddenStateBeforePan = navigationBar.alpha == 0
    }
    
    func previewCell(_ cell: PreviewCell, didPanScale scale: CGFloat) {
        // 实测用 scale 的平方，效果比线性好些
        let alpha = scale * scale
        scalePresentationController?.maskAlpha = alpha
        setBar(hidden: true, isNormal: false)
    }
    
    func previewCell(_ cell: PreviewCell, didEndPanWithExit isExit: Bool) {
        if isExit {
            dismiss(animated: true, completion: nil)
            NotificationCenter.default.post(name: .setupStatusBarHidden, object: false)
        } else if !toolBarHiddenStateBeforePan {
            setBar(hidden: false, isNormal: false)
        }
    }
    
    func previewCellDidSingleTap(_ cell: PreviewCell) {
        setBar(hidden: navigationBar.alpha == 1, animated: false)
    }
    
    func previewCellGetToolBarHiddenState() -> Bool {
        return navigationBar.alpha == 0
    }
}

// MARK: - PickerPreviewIndexViewDelegate
extension PhotoPreviewController: PickerPreviewIndexViewDelegate {
    
    func pickerPreviewIndexView(_ view: PickerPreviewIndexView, didSelect idx: Int) {
        currentIndex = idx
        collectionView.scrollToItem(at: IndexPath(item: idx, section: 0), at: .left, animated: false)
    }
}

// MARK: - UIViewControllerTransitioningDelegate
extension PhotoPreviewController: UIViewControllerTransitioningDelegate {
    /// 提供进场动画
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        updateLayout()
        // 立即加载collectionView
        let indexPath = IndexPath(item: currentIndex, section: 0)
        collectionView.reloadData()
        collectionView.scrollToItem(at: indexPath, at: .left, animated: false)
        collectionView.layoutIfNeeded()
        return makeScalePresentationAnimator(indexPath: indexPath)
    }
    
    /// 提供退场动画
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return makeDismissedAnimator()
    }
    
    /// 提供转场协调器
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let controller = ScalePresentationController(presentedViewController: presented, presenting: presenting)
        scalePresentationController = controller
        return controller
    }
    
    /// 创建缩放型进场动画
    private func makeScalePresentationAnimator(indexPath: IndexPath) -> UIViewControllerAnimatedTransitioning {
        let cell = collectionView.cellForItem(at: indexPath) as? PreviewCell
        let imageView = UIImageView(image: cell?.imageView.image)
        imageView.contentMode = imageScaleMode
        imageView.clipsToBounds = true
        // 创建animator
        return ScaleAnimator(startView: relatedView, endView: cell?.imageView, scaleView: imageView)
    }
    
    /// 创建缩放型退场动画
    private func makeDismissedAnimator() -> UIViewControllerAnimatedTransitioning? {
        guard let cell = collectionView.visibleCells.first as? PreviewCell else {
            return nil
        }
        let imageView = UIImageView(image: cell.imageView.image)
        imageView.contentMode = imageScaleMode
        imageView.clipsToBounds = true
        return ScaleAnimator(startView: cell.imageView, endView: relatedView, scaleView: imageView)
    }
}
