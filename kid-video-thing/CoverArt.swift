//
//  CoverArt.swift
//  kid-video-thing
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds Plex-style poster art from a video's YouTube thumbnail.
///
/// Each video sits in its own folder (see `MediaLayout`), so the poster goes
/// beside it as `poster.jpg`. Plex posters are portrait (2:3), so the 16:9
/// thumbnail is centered on a black canvas rather than cropped, which would cut
/// the middle out of the frame.
nonisolated enum CoverArt {
    /// 2:3, the shape Plex expects. Big enough that Plex never upscales it.
    static let size = CGSize(width: 1000, height: 1500)

    nonisolated enum CoverError: LocalizedError {
        case noVideoID(String)
        case noThumbnail(String)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noVideoID(let url):
                return "Couldn't find a YouTube video ID in \(url)"
            case .noThumbnail(let id):
                return "No usable thumbnail for video \(id)"
            case .encodingFailed:
                return "Couldn't write the cover image"
            }
        }
    }

    /// Where the poster for a given video file belongs.
    static func coverURL(for videoFile: URL) -> URL {
        MediaLayout.posterURL(for: videoFile)
    }

    static func exists(for videoFile: URL) -> Bool {
        FileManager.default.fileExists(atPath: coverURL(for: videoFile).path)
    }

    /// Generates the poster for `videoFile` unless it already has one. Returns the
    /// cover's location when one was written, nil when it was already there.
    @discardableResult
    nonisolated static func ensure(
        videoURL: String, videoFile: URL
    ) async throws -> URL? {
        guard !exists(for: videoFile) else { return nil }
        return try await generate(videoURL: videoURL, videoFile: videoFile)
    }

    nonisolated static func generate(videoURL: String, videoFile: URL) async throws -> URL {
        guard let id = videoID(from: videoURL) else { throw CoverError.noVideoID(videoURL) }
        let thumbnail = try await fetchThumbnail(videoID: id)
        let poster = try compose(thumbnail)

        let destination = coverURL(for: videoFile)
        guard
            let sink = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CoverError.encodingFailed }
        CGImageDestinationAddImage(
            sink, poster, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { throw CoverError.encodingFailed }
        return destination
    }

    // MARK: - Pieces

    /// The thumbnail sizes YouTube serves, best first. `maxresdefault` only exists
    /// for videos uploaded above 720p, so the smaller ones are real fallbacks.
    private static let thumbnailNames = [
        "maxresdefault", "sddefault", "hq720", "hqdefault", "mqdefault",
    ]

    private nonisolated static func fetchThumbnail(videoID: String) async throws -> CGImage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)

        for name in thumbnailNames {
            let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg")!
            guard let (data, response) = try? await session.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            // A missing thumbnail can still come back 200 as a tiny grey placeholder.
            guard image.width >= 320 else { continue }
            return image
        }
        throw CoverError.noThumbnail(videoID)
    }

    /// Centers `thumbnail` on a black 2:3 canvas, scaled to fit whole — the black
    /// ends up as bars above and below a 16:9 frame.
    private nonisolated static func compose(_ thumbnail: CGImage) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CoverError.encodingFailed }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high

        let scale = min(
            size.width / CGFloat(thumbnail.width), size.height / CGFloat(thumbnail.height))
        let drawn = CGSize(
            width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
        context.draw(
            thumbnail,
            in: CGRect(
                x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                width: drawn.width, height: drawn.height))

        guard let image = context.makeImage() else { throw CoverError.encodingFailed }
        return image
    }

    /// A small, cheap version of a poster for list rows — decoded straight to the
    /// size needed rather than loading the full 1000x1500 image.
    static func thumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pulls the 11-character video ID out of the URL shapes YouTube uses.
    static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return nil
        }
        let path = url.pathComponents.filter { $0 != "/" }

        if host.hasSuffix("youtu.be") {
            return path.first.flatMap(valid)
        }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let v = query.first(where: { $0.name == "v" })?.value
        {
            return valid(v)
        }
        // /shorts/ID, /embed/ID, /live/ID, /v/ID
        for (index, component) in path.enumerated()
        where ["shorts", "embed", "live", "v"].contains(component) {
            if index + 1 < path.count { return valid(path[index + 1]) }
        }
        return nil
    }

    private static func valid(_ id: String) -> String? {
        let allowed = CharacterSet(charactersIn: "-_").union(.alphanumerics)
        guard id.count == 11, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return id
    }
}
