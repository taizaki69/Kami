import XCTest
import UIKit
@testable import Kami

/// Hosted simulator tests exercise Core Animation's actual asynchronous tile
/// drawing. The reference UIImageView also catches a flipped drawing context.
@MainActor
final class ReaderTiledImageTests: XCTestCase {
    func testTiledImageMatchesUIKitAcrossTileBoundariesAndAfterReplacement() async throws {
        let first = fixture(reversed: false), second = fixture(reversed: true)
        let (window, reference, tiled) = try makeWindow()
        defer { tiled.setImage(nil); window.isHidden = true }
        for source in [first, second] {
            reference.image = source
            tiled.setImage(source.cgImage)
            try await assertRenderedMatch(reference: reference, tiled: tiled, window: window)
        }
    }

    func testTallPageScrollingAndResizingKeepTheVisibleTileAligned() async throws {
        let image = fixture(reversed: false, height: 2_400)
        let (window, reference, tiled) = try makeWindow()
        defer { tiled.setImage(nil); window.isHidden = true }
        reference.image = image
        tiled.setImage(image.cgImage)
        // Each clipped parent models the visible portion of a webtoon. Move
        // the tall image through it so previously undrawn rows are requested.
        for y in [CGFloat(0), -CGFloat(800), -CGFloat(2_144)] {
            reference.frame = CGRect(x: 0, y: y, width: 128, height: 2_400)
            tiled.frame = reference.frame
            tiled.layoutIfNeeded()
            try await assertRenderedMatch(reference: reference, tiled: tiled, window: window)
        }
        reference.frame = CGRect(x: 0, y: -400, width: 128, height: 1_200)
        tiled.frame = reference.frame
        tiled.layoutIfNeeded()
        try await assertRenderedMatch(reference: reference, tiled: tiled, window: window)
    }

    private func makeWindow() throws -> (UIWindow, UIImageView, ReaderTiledImageView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.backgroundColor = .black
        let left = UIView(frame: CGRect(x: 8, y: 100, width: 128, height: 256))
        let right = UIView(frame: CGRect(x: 152, y: 100, width: 128, height: 256))
        for parent in [left, right] {
            parent.clipsToBounds = true
            parent.backgroundColor = .magenta
            root.view.addSubview(parent)
        }
        let reference = UIImageView(frame: left.bounds)
        reference.contentMode = .scaleToFill
        left.addSubview(reference)
        let tiled = ReaderTiledImageView(frame: right.bounds)
        right.addSubview(tiled)
        root.view.layoutIfNeeded()
        return (window, reference, tiled)
    }

    private func fixture(reversed: Bool, height: Int = 768) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 128, height: height), format: format).image { context in
            let colors: [UIColor] = reversed ? [.yellow, .blue, .green, .red] : [.red, .green, .blue, .yellow]
            for y in stride(from: 0, to: height, by: 64) {
                colors[(y / 64) % 4].setFill()
                context.fill(CGRect(x: 0, y: y, width: 128, height: min(64, height - y)))
            }
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 17, height: height))
        }
    }

    private func assertRenderedMatch(reference: UIImageView, tiled: ReaderTiledImageView, window: UIWindow,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let deadline = Date().addingTimeInterval(8)
        var lastSnapshot: UIImage?
        var lastSamples = "No snapshot"
        repeat {
            window.layoutIfNeeded()
            CATransaction.flush()
            try await Task.sleep(nanoseconds: 100_000_000)
            let snapshot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            lastSnapshot = snapshot
            if let cgImage = snapshot.cgImage {
                let left = try rgba(cgImage, crop: CGRect(x: 8, y: 100, width: 128, height: 256))
                let right = try rgba(cgImage, crop: CGRect(x: 152, y: 100, width: 128, height: 256))
                // Sample away from color boundaries; compare many rows/columns
                // including both sides of the 512-device-pixel tile boundaries.
                let xs = [4, 30, 64, 100, 120], ys = [9, 33, 61, 95, 129, 161, 191, 225, 247]
                let whiteOffset = (9 * 128 + 4) * 4
                lastSamples = [9, 129, 247].map { y in
                    let i = (y * 128 + 30) * 4
                    return "row \(y): reference \(Array(left[i..<(i + 4)])), tiles \(Array(right[i..<(i + 4)]))"
                }.joined(separator: "; ")
                let hasReference = (0..<3).allSatisfy { left[whiteOffset + $0] >= 250 }
                    && Set(ys.map { y in
                        let i = (y * 128 + 30) * 4
                        return [left[i], left[i + 1], left[i + 2]]
                    }).count >= 4
                if hasReference && ys.allSatisfy({ y in xs.allSatisfy { x in
                    (0..<3).allSatisfy { abs(Int(left[(y * 128 + x) * 4 + $0]) - Int(right[(y * 128 + x) * 4 + $0])) <= 3 }
                } }) { return }
            }
        } while Date() < deadline
        if let lastSnapshot {
            let attachment = XCTAttachment(image: lastSnapshot)
            attachment.name = "UIKit reference (left), tiled reader (right)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTFail("Tiled reader did not match UIKit after drawing/scrolling/replacement. \(lastSamples)", file: file, line: line)
    }

    private func rgba(_ image: CGImage, crop: CGRect) throws -> Data {
        let tile = try XCTUnwrap(image.cropping(to: crop))
        var bytes = Data(count: 128 * 256 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 128, height: 256,
                                                 bitsPerComponent: 8, bytesPerRow: 512,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(tile, in: CGRect(x: 0, y: 0, width: 128, height: 256))
        }
        return bytes
    }
}
