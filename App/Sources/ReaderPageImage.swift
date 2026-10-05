import SwiftUI
import UIKit
import MihonCompatKit
import KamiCore

@MainActor
final class ReaderImageStore: ObservableObject {
    @Published private(set) var memoryConstrained = false
    private let pipeline: ReaderImagePipeline?
    private var prefetchTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var pressureTask: Task<Void, Never>?

    init(
        sourceID: String,
        offlineOnly: Bool = false,
        transportPolicy: CompatHTTPTransportPolicy = .init(allowsInsecureHTTP: false)
    ) {
        pipeline = offlineOnly ? nil : ReaderImagePipeline(
            sourceID: sourceID,
            transportPolicy: transportPolicy
        )
    }

    func data(
        for request: ImageRequest,
        policy: ReaderImageLoadPolicy = .useCache
    ) async throws -> Data {
        await pressureTask?.value
        try Task.checkCancellation()
        guard let pipeline else { throw CancellationError() }
        return try await pipeline.data(for: request, policy: policy)
    }

    func data(for lease: OfflineChapterLease, ordinal: Int) async throws -> Data {
        await pressureTask?.value
        try Task.checkCancellation()
        return try await lease.readPage(ordinal: ordinal)
    }

    func handleMemoryPressure() {
        guard !memoryConstrained else { return }
        memoryConstrained = true
        prefetchTask?.cancel()
        prefetchTask = nil
        pressureTask = Task { [pipeline] in await pipeline?.handleMemoryPressure() }
    }

    func prefetch(_ requests: [ImageRequest]) {
        prefetchTask?.cancel()
        guard !memoryConstrained, !requests.isEmpty, let pipeline else { return }
        prefetchTask = Task {
            await pipeline.prefetch(requests)
        }
    }

    func reset() async {
        clearTask?.cancel()
        clearTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        await pressureTask?.value
        await pipeline?.clear()
    }

    func stop() {
        prefetchTask?.cancel()
        prefetchTask = nil
        clearTask?.cancel()
        guard let pipeline else {
            clearTask = nil
            return
        }
        let pressure = pressureTask
        clearTask = Task {
            await pressure?.value
            await pipeline.clear()
        }
    }
}

@MainActor
struct ReaderPageImage: View {
    enum Layout {
        case paged
        case webtoon
    }

    let pageNumber: Int
    let page: PageCompat
    let source: (any KamiSource)?
    let request: ImageRequest?
    let offlineLease: OfflineChapterLease?
    let requestGeneration: Int
    @ObservedObject var store: ReaderImageStore
    let layout: Layout
    let fit: ReaderPageFit
    let trimBorders: Bool
    let rightToLeft: Bool
    let isActive: Bool
    let background: Color
    let foreground: Color
    let onSingleTap: (CGFloat) -> Void
    let onRequestRefresh: @MainActor (ImageRequest?) -> Bool
    var onReadOnline: (() -> Void)? = nil

    @State private var decodedImage: DecodedReaderImage?
    @State private var imageRevision = UUID()
    // Releasing pixels must not collapse the scroll position or change page
    // progress. These tiny measurements survive page deactivation.
    @State private var originalAspect: CGFloat = 2.0 / 3.0
    @State private var croppedAspect: CGFloat = 2.0 / 3.0
    @State private var measuredAspectID: String?
    @State private var loading = true
    @State private var errorText: String?
    @State private var attempt = 0
    @State private var lastResolvedAttempt = 0
    @State private var lastLoadedAttempt = 0

    var body: some View {
        Group {
            if !isActive {
                background.aspectRatio(layout == .webtoon ? presentedAspect : nil, contentMode: .fit)
            } else if let image = presentedImage {
                switch layout {
                case .paged:
                    ZoomableReaderImage(
                        image: image,
                        aspectRatio: presentedAspect,
                        allowsZoom: true,
                        fit: fit, rightToLeft: rightToLeft,
                        memoryConstrained: store.memoryConstrained,
                        onSingleTap: onSingleTap
                    )
                    .id(trimBorders)
                case .webtoon:
                    ZoomableReaderImage(
                        image: image,
                        aspectRatio: presentedAspect,
                        allowsZoom: false,
                        fit: .fitPage, rightToLeft: false,
                        memoryConstrained: store.memoryConstrained,
                        onSingleTap: onSingleTap
                    )
                    .aspectRatio(
                        presentedAspect,
                        contentMode: .fit
                    )
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: layout == .paged ? .infinity : nil)
        .background(background)
        .task(id: loadID) { await loadImage() }
        .task(id: "\(imageRevision):\(store.memoryConstrained):\(isActive)") {
            await reduceResidentImage()
        }
        .onDisappear {
            if layout == .webtoon { releaseImage() }
        }
    }

    private var presentedImage: UIImage? {
        trimBorders ? decodedImage?.croppedImage ?? decodedImage?.image : decodedImage?.image
    }
    private var presentedAspect: CGFloat { trimBorders ? croppedAspect : originalAspect }

    private func releaseImage() {
        decodedImage = nil
        imageRevision = UUID()
    }

    private func reduceResidentImage() async {
        guard store.memoryConstrained, isActive, let decodedImage,
              max(decodedImage.native.image.width, decodedImage.native.image.height) > 2_048 else { return }
        let revision = imageRevision
        do {
            let reduced = try await NativeImageValidation.reducedReaderPage(decodedImage.native)
            guard !Task.isCancelled, revision == imageRevision else { return }
            self.decodedImage = DecodedReaderImage(reduced)
            // Keep the original layout ratio and revision: rounding the new
            // pixels must not move a webtoon or reset a reader's zoom/pan.
        } catch {
            // Retain the readable image if allocation/decoding was interrupted.
            // A new page will still decode at the reduced limit.
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            background
            if loading {
                ProgressView()
                    .tint(foreground)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                    Text(errorText ?? "Failed to load page \(pageNumber)")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") { attempt &+= 1 }
                        .buttonStyle(.bordered)
                    if let onReadOnline {
                        Button("Read online", action: onReadOnline).buttonStyle(.bordered)
                    }
                }
                .foregroundStyle(foreground)
                .padding()
            }
        }
        .aspectRatio(layout == .webtoon ? presentedAspect : nil, contentMode: .fit)
    }

    private var loadID: String {
        "\(requestGeneration):\(attempt):\(isActive)"
    }

    private func loadImage() async {
        guard !Task.isCancelled else { return }
        guard isActive else {
            releaseImage()
            loading = false
            errorText = nil
            return
        }
        loading = true
        errorText = nil
        releaseImage()
        var resolvedRequest = request
        let requestedAttempt = attempt
        if offlineLease == nil, requestedAttempt != lastResolvedAttempt {
            // Retry obtains a new source-owned URL/header snapshot. Ordinary
            // page reactivation keeps the most recently published request.
            resolvedRequest = await source?.getImageRequest(page: page)
            guard !Task.isCancelled,
                  onRequestRefresh(resolvedRequest) else { return }
            lastResolvedAttempt = requestedAttempt
        }
        guard offlineLease != nil || resolvedRequest != nil else {
            errorText = "The source did not provide a valid image request."
            loading = false
            return
        }
        do {
            // Keep a canceled retry's cache bypass pending across page
            // reactivation, without resolving the source snapshot again.
            let policy: ReaderImageLoadPolicy = requestedAttempt == lastLoadedAttempt
                ? .useCache
                : .reload
            let data: Data
            if let offlineLease {
                data = try await store.data(for: offlineLease, ordinal: page.index)
            } else if let resolvedRequest {
                data = try await store.data(for: resolvedRequest, policy: policy)
            } else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            lastLoadedAttempt = requestedAttempt
            let decoded = try await ReaderImageDecoder.decode(
                data,
                maximumPixelDimension: layout == .paged ? 6_144 : 4_096,
                memoryConstrained: store.memoryConstrained
            )
            guard !Task.isCancelled else { return }
            decodedImage = decoded
            let aspectID = "\(requestGeneration):\(requestedAttempt)"
            if measuredAspectID != aspectID {
                originalAspect = max(decoded.image.size.width, 1) / max(decoded.image.size.height, 1)
                let crop = decoded.croppedImage ?? decoded.image
                croppedAspect = max(crop.size.width, 1) / max(crop.size.height, 1)
                measuredAspectID = aspectID
            }
            imageRevision = UUID()
            loading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorText = offlineLease == nil
                ? error.localizedDescription
                : "This downloaded page could not be read. Retry the local file or re-download the chapter from Downloads."
            loading = false
        }
    }
}

private struct ZoomableReaderImage: View {
    let image: UIImage
    let aspectRatio: CGFloat
    let allowsZoom: Bool
    let fit: ReaderPageFit
    let rightToLeft: Bool
    let memoryConstrained: Bool
    let onSingleTap: (CGFloat) -> Void

    @State private var scale: Double = 1
    @State private var settledScale: Double = 1
    @State private var offset = ReaderPageOffset()
    @State private var settledOffset = ReaderPageOffset()

    var body: some View {
        GeometryReader { proxy in
            let plan = ReaderPageLayout(imageWidth: Double(aspectRatio), imageHeight: 1,
                                        viewportWidth: Double(proxy.size.width), viewportHeight: Double(proxy.size.height),
                                        fit: fit, rightToLeft: rightToLeft)
            imageSurface(plan: plan)
                .onAppear { reset(plan: plan) }
                .onChange(of: plan) { _, updated in reset(plan: updated) }
                .onChange(of: fit) { _, _ in reset(plan: plan) }
                .onChange(of: rightToLeft) { _, _ in reset(plan: plan) }
        }
        .clipped()
    }

    @ViewBuilder
    private func imageSurface(plan: ReaderPageLayout) -> some View {
        let content = ReaderTiledImage(image: image.cgImage)
            // Drop rendered tile caches after pressure/replacement while
            // preserving this parent's page geometry and zoom/pan state.
            .id(TileIdentity(image: ObjectIdentifier(image), constrained: memoryConstrained))
            .frame(width: CGFloat(plan.width), height: CGFloat(plan.height))
            .scaleEffect(CGFloat(scale))
            .offset(x: CGFloat(offset.x), y: CGFloat(offset.y))
            .frame(width: CGFloat(plan.viewportWidth), height: CGFloat(plan.viewportHeight))
            .contentShape(Rectangle())
            .clipped()
        if allowsZoom {
            content.highPriorityGesture(tapGesture(plan: plan))
                .highPriorityGesture(panGesture(plan: plan), including: plan.canPan(scale: scale) ? .all : .subviews)
                .simultaneousGesture(magnifyGesture(plan: plan))
        } else {
            content.highPriorityGesture(SpatialTapGesture(count: 1).onEnded { tap in
                onSingleTap(tap.location.x / CGFloat(max(plan.viewportWidth, 1)))
            })
        }
    }

    private struct TileIdentity: Hashable {
        let image: ObjectIdentifier
        let constrained: Bool
    }

    private func reset(plan: ReaderPageLayout) {
        scale = 1; settledScale = 1
        offset = plan.initialOffset; settledOffset = offset
    }

    private func tapGesture(plan: ReaderPageLayout) -> some Gesture {
        SpatialTapGesture(count: 2)
            .exclusively(before: SpatialTapGesture(count: 1))
            .onEnded { value in
                switch value {
                case let .first(tap):
                    guard allowsZoom else {
                        onSingleTap(tap.location.x / CGFloat(max(plan.viewportWidth, 1))); return
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        let next = scale > 1 ? 1.0 : 2.5
                        offset = plan.zoomedOffset(offset, from: scale, to: next,
                                                   anchor: .init(x: Double(tap.location.x) - plan.viewportWidth / 2,
                                                                 y: Double(tap.location.y) - plan.viewportHeight / 2))
                        scale = next; settledScale = next; settledOffset = offset
                    }
                case let .second(tap):
                    onSingleTap(tap.location.x / CGFloat(max(plan.viewportWidth, 1)))
                }
            }
    }

    private func magnifyGesture(plan: ReaderPageLayout) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard allowsZoom else { return }
                let next = ReaderPageLayout.normalizedScale(settledScale * Double(value.magnification))
                offset = plan.zoomedOffset(settledOffset, from: settledScale, to: next)
                scale = next
            }
            .onEnded { _ in
                guard allowsZoom else { return }
                settledScale = scale
                offset = plan.boundedOffset(offset, scale: scale)
                settledOffset = offset
            }
    }

    private func panGesture(plan: ReaderPageLayout) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard allowsZoom, plan.canPan(scale: scale) else { return }
                offset = plan.boundedOffset(.init(x: settledOffset.x + Double(value.translation.width),
                                                  y: settledOffset.y + Double(value.translation.height)), scale: scale)
            }
            .onEnded { _ in
                guard allowsZoom, plan.canPan(scale: scale) else { return }
                settledOffset = offset
            }
    }
}

private struct DecodedReaderImage: @unchecked Sendable {
    let native: NativePageImage
    let image: UIImage
    let croppedImage: UIImage?

    init(_ native: NativePageImage) {
        self.native = native
        image = UIImage(cgImage: native.image)
        croppedImage = native.borderTrimmedImage.map { UIImage(cgImage: $0) }
    }
}

private enum ReaderImageDecoder {
    static func decode(
        _ data: Data,
        maximumPixelDimension: Int,
        memoryConstrained: Bool
    ) async throws -> DecodedReaderImage {
        let result = try await NativeImageValidation.readerPage(
            data: data, ordinaryMaximumDimension: maximumPixelDimension,
            memoryConstrained: memoryConstrained, prepareBorderTrim: true
        )
        try Task.checkCancellation()
        return DecodedReaderImage(result)
    }
}
