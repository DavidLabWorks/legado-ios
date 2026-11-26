import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PreviewPhoto {
    let data: Data
    let image: UIImage

    init(data: Data) throws {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw URLError(.cannotDecodeContentData)
        }
        self.data = data
        self.image = image
    }
}

struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    private let pageCount: Int
    private let imageLabel: String
    private let loadPhoto: (Int, _ retry: Bool) async throws -> PreviewPhoto
    @State private var index: Int
    @State private var photos: [Int: PreviewPhoto] = [:]
    @State private var failed: Set<Int> = []
    @State private var message: String?
    @State private var saving = false
    @State private var showsControls = true

    private enum Screen { case photo, overview, photoFromOverview }
    @State private var screen = Screen.photo
    @State private var thumbnails: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = 80
        return cache
    }()

    private let onLocate: ((Int) -> Void)?

    init(pageCount: Int = 1, index: Int = 0, imageLabel: String = "图片",
         onLocate: ((Int) -> Void)? = nil, loadPhoto: @escaping (Int, _ retry: Bool) async throws -> PreviewPhoto) {
        self.pageCount = pageCount
        self.imageLabel = imageLabel
        self.onLocate = onLocate
        self.loadPhoto = loadPhoto
        _index = State(initialValue: index)
    }

    var body: some View {
        ZStack {
            if screen == .overview {
                overview
            } else {
                pager
                    .overlay(alignment: .top) { if controlsAreVisible { photoHeader } }
                    .overlay(alignment: .bottom) { if controlsAreVisible { photoFooter } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .buttonStyle(PhotoControlStyle())
        .tint(.white)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .accessibilityAction(.escape, goBack)
        .alert("图片", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(0..<pageCount, id: \.self) { page in
                ZStack {
                    Color.black
                    ZoomablePhoto(photo: photos[page], imageLabel: imageLabel, selected: page == index, onDismiss: goBack)
                        .simultaneousGesture(TapGesture().onEnded { showsControls.toggle() })
                    if failed.contains(page) {
                        VStack(spacing: 12) {
                            ReadingUnavailableView("图片加载失败", systemImage: "photo.badge.exclamationmark")
                                .allowsHitTesting(false)
                            Button("重新加载") { Task { await load(page, retry: true) } }
                                .buttonStyle(.bordered)
                        }
                    } else if photos[page] == nil {
                        RagdollLoading(width: 80).allowsHitTesting(false)
                    }
                }
                .ignoresSafeArea()
                .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .task(id: index) {
            let current = index
            photos = photos.filter { abs($0.key - current) <= 1 }
            if (0..<pageCount).contains(current), photos[current] == nil, !failed.contains(current) {
                await load(current)
            }
        }
    }

    private var backButton: some View {
        Button(action: goBack) {
            Image(systemName: screen == .photo ? "xmark" : "chevron.left")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(screen == .photo ? "关闭图片预览" : screen == .overview ? "返回大图" : "返回图片列表")
    }

    private var photoHeader: some View {
        HStack {
            backButton
            Spacer()
            if let onLocate {
                Button {
                    onLocate(index)
                    dismiss()
                } label: {
                    Label("定位到原文", systemImage: "scope")
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .accessibilityHint("返回原文并滚动到当前图片")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var photoFooter: some View {
        HStack(spacing: 8) {
            Text("\(index + 1) / \(pageCount)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(.thinMaterial, in: Capsule())
            Spacer()
            Button(action: save) {
                HStack(spacing: 6) {
                    if saving { RagdollLoading(width: 28) }
                    else { Image(systemName: "arrow.down.to.line") }
                    Text("保存")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
            }
            .accessibilityLabel("保存到照片")
            .disabled(photos[index] == nil || saving)
            if pageCount > 1 {
                Button { screen = .overview } label: {
                    Image(systemName: "square.grid.2x2.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("图片列表")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var overview: some View {
        VStack(spacing: 12) {
            HStack {
                backButton
                Text("全部图片").font(.headline)
                Spacer()
                Text("共 \(pageCount) 张").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(0..<pageCount, id: \.self) { page in
                            Button {
                                index = page
                                showsControls = true
                                screen = .photoFromOverview
                            } label: {
                                PhotoThumbnail(selected: page == index) {
                                    try await thumbnail(for: page)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("第 \(page + 1) 张图片")
                            .accessibilityAddTraits(page == index ? .isSelected : [])
                            .id(page)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onAppear { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func thumbnail(for page: Int) async throws -> UIImage {
        let key = NSNumber(value: page)
        if let cached = thumbnails.object(forKey: key) { return cached }

        let photo: PreviewPhoto
        if let loaded = photos[page] {
            photo = loaded
        } else {
            photo = try await loadPhoto(page, false)
        }
        try Task.checkCancellation()
        guard let thumbnail = await photo.image.byPreparingThumbnail(ofSize: CGSize(width: 320, height: 320)) else {
            throw URLError(.cannotDecodeContentData)
        }
        try Task.checkCancellation()
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    private func goBack() {
        switch screen {
        case .photo: dismiss()
        case .overview: screen = .photo
        case .photoFromOverview: screen = .overview
        }
    }

    private var controlsAreVisible: Bool {
        showsControls || photos[index] == nil
    }

    private func load(_ page: Int, retry: Bool = false) async {
        failed.remove(page)
        do {
            let photo = try await loadPhoto(page, retry)
            try Task.checkCancellation()
            if abs(index - page) <= 1 { photos[page] = photo }
        } catch {
            guard !Task.isCancelled else { return }
            failed.insert(page)
            if pageCount == 1 { message = "加载图片失败：\(error.localizedDescription)" }
        }
    }

    private func save() {
        guard let photo = photos[index], !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { message = "请在系统设置中允许添加照片"; return }
            do {
                try await PHPhotoLibrary.shared().performChanges { @Sendable [data = photo.data] in
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                message = "已保存到照片"
            } catch { message = "保存失败：\(error.localizedDescription)" }
        }
    }
}

private struct PhotoControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

private struct PhotoThumbnail: View {
    let selected: Bool
    let load: () async throws -> UIImage
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    RagdollLoading()
                }
            }
            .clipShape(tile)
            .overlay { if selected { tile.strokeBorder(.white, lineWidth: 3) } }
            .contentShape(tile)
            .task {
                guard image == nil else { return }
                do { image = try await load() }
                catch { if !Task.isCancelled { failed = true } }
            }
    }
}

private struct ZoomablePhoto: UIViewRepresentable {
    let photo: PreviewPhoto?
    let imageLabel: String
    let selected: Bool
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }

    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.accessibilityLabel = imageLabel
        view.onDismiss = onDismiss
        view.display(photo, selected: selected)
        if !selected && view.zoomScale != 1 { view.setZoomScale(1, animated: false) }
    }

    final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
        private let photo = UIImageView()
        private var poster: UIImage?
        private var isSelected = false
        private var playbackID = UUID()
        var onDismiss: (() -> Void)?
        private var viewport: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            maximumZoomScale = 6
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            panGestureRecognizer.isEnabled = false
            accessibilityIdentifier = "website.gallery.photo"
            isAccessibilityElement = true
            accessibilityTraits = .image
            addSubview(photo)
            for direction: UISwipeGestureRecognizer.Direction in [.up, .down] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(dismissPhoto))
                swipe.direction = direction
                addGestureRecognizer(swipe)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UISwipeGestureRecognizer { return !isZooming && zoomScale <= 1.001 }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        @objc private func dismissPhoto() { onDismiss?() }

        func display(_ loaded: PreviewPhoto?, selected: Bool) {
            guard poster !== loaded?.image || isSelected != selected else { return }
            isSelected = selected
            playbackID = UUID()
            poster = loaded?.image
            photo.image = poster
            viewport = .zero
            setNeedsLayout()
            guard selected, let data = loaded?.data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) == UTType.gif.identifier as CFString,
                  CGImageSourceGetCount(source) > 1 else { return }

            let id = playbackID
            CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, frame, stop in
                guard let self, playbackID == id else {
                    stop.pointee = true
                    return
                }
                photo.image = UIImage(cgImage: frame)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != viewport, bounds.width > 0, bounds.height > 0, let size = poster?.size {
                viewport = bounds.size
                setZoomScale(1, animated: false)
                let scale = min(viewport.width / size.width, viewport.height / size.height)
                photo.frame = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
                contentSize = photo.frame.size
                centerPhoto()
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            panGestureRecognizer.isEnabled = zoomScale > 1.001
            centerPhoto()
        }

        private func centerPhoto() {
            let x = max(0, (bounds.width - contentSize.width) / 2)
            let y = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
        }
    }
}
