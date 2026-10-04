import SwiftUI
import UIKit
import MihonCompatKit
import KamiCore

@MainActor
final class ReaderImageStore: ObservableObject {
    private let pipeline: ReaderImagePipeline?
    private var prefetchTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

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
        guard let pipeline else { throw CancellationError() }
        return try await pipeline.data(for: request, policy: policy)
    }

    func data(for lease: OfflineChapterLease, ordinal: Int) async throws -> Data {
        try await lease.readPage(ordinal: ordinal)
    }

    func prefetch(_ requests: [ImageRequest]) {
        prefetchTask?.cancel()
        guard !requests.isEmpty, let pipeline else { return }
        prefetchTask = Task {
            await pipeline.prefetch(requests)
        }
    }

    func reset() async {
        clearTask?.cancel()
        clearTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
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
        clearTask = Task { await pipeline.clear() }
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
    let isActive: Bool
    let background: Color
    let foreground: Color
    let onSingleTap: (CGFloat) -> Void
    let onRequestRefresh: @MainActor (ImageRequest?) -> Bool
    var onReadOnline: (() -> Void)? = nil

    @State private var image: UIImage?
    @State private var loading = true
    @State private var errorText: String?
    @State private var attempt = 0
    @State private var lastResolvedAttempt = 0
    @State private var lastLoadedAttempt = 0

    var body: some View {
        Group {
            if !isActive {
                background
            } else if let image {
                switch layout {
                case .paged:
                    ZoomableReaderImage(
                        image: image,
                        allowsZoom: true,
                        onSingleTap: onSingleTap
                    )
                case .webtoon:
                    ZoomableReaderImage(
                        image: image,
                        allowsZoom: false,
                        onSingleTap: onSingleTap
                    )
                    .aspectRatio(
                        max(image.size.width, 1) / max(image.size.height, 1),
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
        .onDisappear {
            if layout == .webtoon { image = nil }
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
        .aspectRatio(layout == .webtoon ? 2.0 / 3.0 : nil, contentMode: .fit)
    }

    private var loadID: String {
        "\(requestGeneration):\(attempt):\(isActive)"
    }

    private func loadImage() async {
        guard !Task.isCancelled else { return }
        guard isActive else {
            image = nil
            loading = false
            errorText = nil
            return
        }
        loading = true
        errorText = nil
        image = nil
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
                maximumPixelDimension: layout == .paged ? 6_144 : 4_096
            )
            guard !Task.isCancelled else { return }
            image = decoded.image
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
    let allowsZoom: Bool
    let onSingleTap: (CGFloat) -> Void

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            if allowsZoom {
                zoomableImage
                    .highPriorityGesture(tapGesture(width: proxy.size.width))
                    .simultaneousGesture(magnifyGesture)
                    .simultaneousGesture(panGesture)
            } else {
                fittedImage
                    .highPriorityGesture(singleTapGesture(width: proxy.size.width))
            }
        }
        .clipped()
    }

    private var fittedImage: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private var zoomableImage: some View {
        fittedImage
            .scaleEffect(scale)
            .offset(offset)
    }

    private func singleTapGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { tap in
                onSingleTap(tap.location.x / max(width, 1))
            }
    }

    private func tapGesture(width: CGFloat) -> some Gesture {
        TapGesture(count: 2)
            .exclusively(before: SpatialTapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    guard allowsZoom else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1 {
                            scale = 1
                            settledScale = 1
                            offset = .zero
                            settledOffset = .zero
                        } else {
                            scale = 2.5
                            settledScale = 2.5
                        }
                    }
                case let .second(tap):
                    onSingleTap(tap.location.x / max(width, 1))
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard allowsZoom else { return }
                scale = min(5, max(1, settledScale * value.magnification))
            }
            .onEnded { _ in
                guard allowsZoom else { return }
                settledScale = scale
                if scale <= 1 {
                    offset = .zero
                    settledOffset = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard allowsZoom, scale > 1 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard allowsZoom, scale > 1 else { return }
                settledOffset = offset
            }
    }
}

private struct DecodedReaderImage: @unchecked Sendable {
    let image: UIImage
}

private enum ReaderImageDecoder {
    static func decode(
        _ data: Data,
        maximumPixelDimension: Int
    ) async throws -> DecodedReaderImage {
        let result = try await NativeImageValidation.thumbnail(
            data: data, maximumPixelDimension: maximumPixelDimension
        )
        try Task.checkCancellation()
        return DecodedReaderImage(image: UIImage(cgImage: result.image))
    }
}
