//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Foundation
import JellyfinAPI
import Logging

final class HLSPlaylistRewriter: NSObject, AVAssetResourceLoaderDelegate {

    private struct Subtitle {
        let index: Int
        let name: String
        let language: String
        let isForced: Bool
    }

    private struct Audio {
        let name: String
        let language: String
    }

    private static let scheme = "jfhls"
    private static let logger = Logger.swiftfin()

    private let realURL: URL
    private let mediaSourceID: String
    private let apiKey: String
    private let subtitles: [Subtitle]
    private let audio: Audio?

    static func makeAsset(for item: MediaPlayerItem) -> (AVURLAsset, HLSPlaylistRewriter)? {

        // Live streams deliver a multi-variant, continuously-growing master playlist.
        // Routing it through the custom-scheme resource loader does not fix the live
        // failures (those are source/timestamp issues), so let AVPlayer load the server
        // playlist directly and keep all variants available as fallbacks.
        guard item.baseItem.isLiveStream != true else {
            return nil
        }

        guard item.url.absoluteString.contains(".m3u8"),
              var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        guard let mediaSourceID = queryItems.first(where: { $0.name == "MediaSourceId" })?.value,
              let apiKey = queryItems.first(where: { $0.name == "ApiKey" })?.value
        else {
            return nil
        }

        let realURL = item.url

        let subtitles: [Subtitle] = item.subtitleStreams.compactMap { stream in
            guard let index = stream.index, stream.isTextSubtitleStream == true else { return nil }
            return Subtitle(
                index: index,
                name: stream.displayTitle ?? stream.language ?? "Subtitle",
                language: stream.language ?? "Unknown",
                isForced: stream.isForced ?? false
            )
        }

        let audioStreamIndex = queryItems.first(where: { $0.name == "AudioStreamIndex" })?.value.flatMap(Int.init)
        let audio: Audio? = item.audioStreams
            .first(where: { $0.index == audioStreamIndex })
            .map { Audio(name: $0.displayTitle ?? $0.language ?? "Audio", language: $0.language ?? "und") }

        components.scheme = scheme

        guard let customURL = components.url else { return nil }

        let rewriter = HLSPlaylistRewriter(
            realURL: realURL,
            mediaSourceID: mediaSourceID,
            apiKey: apiKey,
            subtitles: subtitles,
            audio: audio
        )

        logger
            .info(
                "HLS rewriter engaged for \(realURL.absoluteString) with \(subtitles.count) subtitle and \(audio == nil ? 0 : 1) audio renditions to inject"
            )

        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(rewriter, queue: .main)

        return (asset, rewriter)
    }

    private init(realURL: URL, mediaSourceID: String, apiKey: String, subtitles: [Subtitle], audio: Audio?) {
        self.realURL = realURL
        self.mediaSourceID = mediaSourceID
        self.apiKey = apiKey
        self.subtitles = subtitles
        self.audio = audio
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }

        Self.logger.info("HLS rewriter handling request: \(url.absoluteString)")

        Task { @MainActor in
            await load(loadingRequest)
        }

        return true
    }

    private func load(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: realURL)

            guard let playlist = String(data: data, encoding: .utf8) else {
                loadingRequest.finishLoading(with: URLError(.cannotDecodeContentData))
                return
            }

            let outData = Data(rewrite(playlist: playlist).utf8)

            if let contentRequest = loadingRequest.contentInformationRequest {
                contentRequest.contentType = "application/vnd.apple.mpegurl"
                contentRequest.contentLength = Int64(outData.count)
                contentRequest.isByteRangeAccessSupported = false
            }

            loadingRequest.dataRequest?.respond(with: outData)
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private func rewrite(playlist: String) -> String {
        let lines = playlist.components(separatedBy: "\n")

        let hasExistingSubtitles = lines.contains { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=SUBTITLES") }
        let inject = !subtitles.isEmpty && !hasExistingSubtitles
        let hasExistingAudio = lines.contains { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") }
        let injectAudio = audio != nil && !hasExistingAudio

        var streamInfSuffix = ""
        if injectAudio { streamInfSuffix += ",AUDIO=\"aud\"" }
        if inject { streamInfSuffix += ",SUBTITLES=\"subs\"" }

        var output: [String] = []

        for line in lines {
            if line.hasPrefix("#EXTM3U") {
                output.append(line)

                if let audio, injectAudio {
                    output.append(audioMediaLine(audio))
                }

                if inject {
                    output.append(contentsOf: subtitles.map(mediaLine(for:)))
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                output.append(line + streamInfSuffix)
            } else if line.hasPrefix("#") {
                output.append(absolutizeURIAttribute(line))
            } else if line.isEmpty {
                output.append(line)
            } else {
                output.append(absolutize(line))
            }
        }

        Self.logger
            .info("HLS rewriter injected \(injectAudio ? 1 : 0) audio and \(inject ? subtitles.count : 0) subtitle renditions")

        return output.joined(separator: "\n")
    }

    private func audioMediaLine(_ audio: Audio) -> String {
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(audio.name)\",LANGUAGE=\"\(audio.language)\",DEFAULT=YES,AUTOSELECT=YES"
    }

    private func mediaLine(for subtitle: Subtitle) -> String {
        "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(subtitle.name)\",DEFAULT=NO,FORCED=\(subtitle.isForced ? "YES" : "NO"),AUTOSELECT=YES,URI=\"\(subtitleURI(index: subtitle.index))\",LANGUAGE=\"\(subtitle.language)\""
    }

    private func subtitleURI(index: Int) -> String {
        var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false)
        let basePath = (realURL.path as NSString).deletingLastPathComponent
        components?.path = "\(basePath)/\(mediaSourceID)/Subtitles/\(index)/subtitles.m3u8"
        components?.query = "SegmentLength=30&ApiKey=\(apiKey)"
        return components?.url?.absoluteString ?? ""
    }

    private func absolutizeURIAttribute(_ line: String) -> String {
        guard let range = line.range(of: "URI=\"[^\"]*\"", options: .regularExpression) else {
            return line
        }
        let uri = line[range].dropFirst(5).dropLast()
        return line.replacingCharacters(in: range, with: "URI=\"\(absolutize(String(uri)))\"")
    }

    private func absolutize(_ uri: String) -> String {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") { return uri }
        return URL(string: uri, relativeTo: realURL)?.absoluteString ?? uri
    }
}
