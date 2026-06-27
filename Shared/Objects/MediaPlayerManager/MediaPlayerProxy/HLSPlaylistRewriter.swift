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
        let isHearingImpaired: Bool
    }

    private enum SubtitleRole {
        case full
        case forced
        case sdh
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
    private var cachedSubtitleLines: [String]?

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

        // Inject every text subtitle track. AVKit's native picker labels options by LANGUAGE
        // (ignoring NAME) and collapses same-language tracks unless they differ by FORCED or
        // accessibility characteristics, so each track's role (forced / full / SDH) is resolved
        // from its cue density once the master is served (see classifyRoles) and encoded into
        // those attributes to keep every entry distinct and correctly auto-selected.
        let subtitles: [Subtitle] = item.subtitleStreams.compactMap { stream -> Subtitle? in
            guard let index = stream.index, stream.isTextSubtitleStream == true else { return nil }
            return Subtitle(
                index: index,
                name: stream.displayTitle ?? stream.language ?? "Subtitle",
                language: stream.language ?? "Unknown",
                isForced: stream.isForced ?? false,
                isHearingImpaired: stream.isHearingImpaired ?? false
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

            let rewritten = await rewrite(playlist: playlist, subtitleLines: resolvedSubtitleLines())

            let outData = Data(rewritten.utf8)

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

    private func rewrite(playlist: String, subtitleLines: [String]) -> String {
        let lines = playlist.components(separatedBy: "\n")

        let hasExistingSubtitles = lines.contains { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=SUBTITLES") }
        let inject = !subtitleLines.isEmpty && !hasExistingSubtitles
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
                    output.append(contentsOf: subtitleLines)
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
            .info("HLS rewriter injected \(injectAudio ? 1 : 0) audio and \(inject ? subtitleLines.count : 0) subtitle renditions")

        return output.joined(separator: "\n")
    }

    private func audioMediaLine(_ audio: Audio) -> String {
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(audio.name)\",LANGUAGE=\"\(audio.language)\",DEFAULT=YES,AUTOSELECT=YES"
    }

    /// Builds the injected `#EXT-X-MEDIA` subtitle renditions once, caching the result so the
    /// cue counts are only fetched the first time the master playlist is served.
    private func resolvedSubtitleLines() async -> [String] {
        if let cachedSubtitleLines { return cachedSubtitleLines }

        guard !subtitles.isEmpty else {
            cachedSubtitleLines = []
            return []
        }

        let cueCounts = await cueCounts(for: subtitles)
        let lines = subtitleMediaLines(subtitles, cueCounts: cueCounts)
        cachedSubtitleLines = lines

        return lines
    }

    /// Resolves each track's role from the relative cue density within its language group, since
    /// the source metadata often can't distinguish forced / full / SDH variants:
    /// - one track for a language is the full subtitle;
    /// - two tracks → the sparser one is forced (foreign-dialogue only), the denser one is full;
    /// - three or more → sparsest is forced, densest is SDH (adds sound/music cues), rest are full.
    private func classifyRoles(_ subtitles: [Subtitle], cueCounts: [Int: Int]) -> [Int: SubtitleRole] {
        var byLanguage: [String: [Subtitle]] = [:]
        for subtitle in subtitles {
            byLanguage[subtitle.language, default: []].append(subtitle)
        }

        var roles: [Int: SubtitleRole] = [:]
        for group in byLanguage.values {
            guard group.count > 1 else {
                group.forEach { roles[$0.index] = .full }
                continue
            }

            let sorted = group.sorted { (cueCounts[$0.index] ?? 0) < (cueCounts[$1.index] ?? 0) }
            for (offset, subtitle) in sorted.enumerated() {
                if offset == 0 {
                    roles[subtitle.index] = .forced
                } else if offset == sorted.count - 1, sorted.count >= 3 {
                    roles[subtitle.index] = .sdh
                } else {
                    roles[subtitle.index] = .full
                }
            }
        }
        return roles
    }

    private func subtitleMediaLines(_ subtitles: [Subtitle], cueCounts: [Int: Int]) -> [String] {
        let roles = classifyRoles(subtitles, cueCounts: cueCounts)
        var usedNames: Set<String> = []

        return subtitles.map { subtitle in
            let role = roles[subtitle.index] ?? .full

            // Guarantee a unique NAME so renditions that AVKit would otherwise treat as identical
            // stay valid; the picker labels by LANGUAGE regardless.
            var uniqueName = subtitle.name
            var suffix = 2
            while !usedNames.insert(uniqueName).inserted {
                uniqueName = "\(subtitle.name) (\(suffix))"
                suffix += 1
            }

            // FORCED=YES tracks are auto-applied with matching audio and hidden from the picker;
            // full and SDH tracks stay selectable, with SDH carrying accessibility characteristics
            // so it reads as a distinct option (and honours the system "Closed Captions + SDH" setting).
            var line = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(uniqueName)\",DEFAULT=NO,FORCED=\(role == .forced ? "YES" : "NO"),AUTOSELECT=YES"
            if role == .sdh {
                line += ",CHARACTERISTICS=\"public.accessibility.describes-music-and-sound,public.accessibility.transcribes-spoken-dialog\""
            }
            line += ",URI=\"\(subtitleURI(index: subtitle.index))\",LANGUAGE=\"\(subtitle.language)\""
            return line
        }
    }

    /// Fetches every track's WebVTT in parallel and counts its cues (`-->` arrows).
    private func cueCounts(for subtitles: [Subtitle]) async -> [Int: Int] {
        let requests: [(index: Int, url: URL)] = subtitles.compactMap { subtitle in
            guard let url = streamVttURL(index: subtitle.index) else { return nil }
            return (subtitle.index, url)
        }

        return await withTaskGroup(of: (Int, Int).self) { group in
            for request in requests {
                group.addTask {
                    guard let (data, _) = try? await URLSession.shared.data(from: request.url),
                          let text = String(data: data, encoding: .utf8)
                    else {
                        return (request.index, 0)
                    }
                    return (request.index, text.components(separatedBy: "-->").count - 1)
                }
            }

            var counts: [Int: Int] = [:]
            for await (index, count) in group {
                counts[index] = count
            }
            return counts
        }
    }

    private func streamVttURL(index: Int) -> URL? {
        var components = URLComponents(url: realURL, resolvingAgainstBaseURL: false)
        let basePath = (realURL.path as NSString).deletingLastPathComponent
        components?.path = "\(basePath)/\(mediaSourceID)/Subtitles/\(index)/0/Stream.vtt"
        components?.query = "ApiKey=\(apiKey)"
        return components?.url
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
