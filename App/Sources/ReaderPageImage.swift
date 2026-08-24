import SwiftUI
import UIKit
import ImageIO
import MihonCompatKit
import KamiCore

@MainActor
final class ReaderImageStore: ObservableObject {
    private let pipeline: ReaderImagePipeline
    private var prefetchTask: Task<Void, Never>?

    init(sourceID: String) {
        pipeline = ReaderImagePipeline(sourceID: sourceID)
    }

    func data(for request: ImageRequest) async throws -> Data {
        try await pipeline.data(for: request)
    }

    func prefetch(_ requests: [ImageRequest]) {
        prefetchTask?.cancel()
        guard !requests.isEmpty else { return }
        let pipeline = self.pipeline
        prefetchTask = Task {
            await pipeline.prefetch(requests)
        }
    }

    func reset() async {
        prefetchTask?.cancel()
        prefetchTask = nil
        await pipeline.clear()
    }

    func stop() {
        prefetchTask?.cancel()
        prefetchTask = nil
        let pipeline = self.pipeline
        Task { await pipeline.clear() }
    }
}

struct ReaderPageImage: View {
    enum Layout {
        case paged
        case webtoon
    }

    let pageNumber: Int
    let request: ImageRequest?
    @ObservedObject var store: ReaderImageStore
    let layout: Layout
    let isActive: Bool
    let background: Color
    let foreground: Color
    let onSingleTap: (CGFloat) -> Void

    @State private var image: UIImage?
    @State private var loading = true
    @State private var errorText: String?
    @State private var attempt = 0

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
                    Button("Retry") { attempt += 1 }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(foreground)
                .padding()
            }
        }
        .aspectRatio(layout == .webtoon ? 2.0 / 3.0 : nil, contentMode: .fit)
    }

    private var loadID: String {
        "\(attempt):\(isActive)"
    }

    private func loadImage() async {
        guard isActive else {
            image = nil
            loading = false
            errorText = nil
            return
        }
        loading = true
        errorText = nil
        image = nil
        guard let request else {
            errorText = "The source did not provide a valid image request."
            loading = false
            return
        }
        do {
            let data = try await store.data(for: request)
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
            errorText = error.localizedDescription
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

private enum ReaderImageDecodeError: Error, LocalizedError {
    case invalidImage
    case dimensionsTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "The page response is not a supported image."
        case .dimensionsTooLarge: return "The page image dimensions exceed the safety limit."
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
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                      source,
                      0,
                      nil
                  ) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw ReaderImageDecodeError.invalidImage
            }
            let pixelWidth = width.intValue
            let pixelHeight = height.intValue
            guard pixelWidth > 0, pixelHeight > 0,
                  pixelWidth <= 100_000, pixelHeight <= 100_000,
                  Int64(pixelWidth) * Int64(pixelHeight) <= 250_000_000 else {
                throw ReaderImageDecodeError.dimensionsTooLarge
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize:
                    max(512, min(maximumPixelDimension, 8_192)),
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                throw ReaderImageDecodeError.invalidImage
            }
            return DecodedReaderImage(image: UIImage(cgImage: thumbnail))
        }.value
    }
}
