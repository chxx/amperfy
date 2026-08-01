//
//  ExternalLyricsSyncCoordinator.swift
//  Amperfy
//

import AmperfyKit
import AVFoundation
import Foundation

// MARK: - ExternalLyricsMessage

struct ExternalLyricsMessage: Encodable, Equatable {
  let version = 1
  let sequence: Int
  let type: String
  let trackId: String
  let title: String
  let artist: String
  let positionMs: Int
  let lineStartMs: Int
  let text: String
  let isPlaying: Bool
}

// MARK: - ExternalLyricsSyncCoordinator

@MainActor
final class ExternalLyricsSyncCoordinator: MusicPlayable {
  static let enabledDefaultsKey = "externalLyricsBluetoothEnabled"

  typealias LyricsLoader = @MainActor (Song) async throws -> StructuredLyrics?

  private let player: PlayerFacade
  private let transport: BluetoothLyricsTransport
  private let lyricsLoader: LyricsLoader
  private var loadTask: Task<Void, Never>?
  private var song: Song?
  private var lyrics: StructuredLyrics?
  private var currentLineIndex: Int?
  private var sequence = 0
  private var lastPositionMs = 0
  private var isPlaying = false

  init(
    player: PlayerFacade,
    transport: BluetoothLyricsTransport = .shared,
    lyricsLoader: @escaping LyricsLoader
  ) {
    self.player = player
    self.transport = transport
    self.lyricsLoader = lyricsLoader
  }

  func start() {
    player.addNotifier(notifier: self)
    setEnabled(UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey))
  }

  func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
    transport.setEnabled(enabled)
    if enabled {
      isPlaying = player.isPlaying
      loadCurrentSong()
    } else {
      loadTask?.cancel()
      resetTimeline()
    }
  }

  private func loadCurrentSong() {
    loadTask?.cancel()
    resetTimeline()

    guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey),
          let song = player.currentlyPlaying?.asSong
    else {
      sendClearMessage()
      return
    }

    self.song = song
    sendMessage(type: "track", line: nil, positionMs: Int(player.elapsedTime * 1_000))
    loadTask = Task { @MainActor [weak self, weak song] in
      guard let self, let song else { return }
      do {
        let loadedLyrics = try await lyricsLoader(song)
        try Task.checkCancellation()
        guard song == player.currentlyPlaying?.asSong else { return }
        guard let loadedLyrics, loadedLyrics.synced else {
          lyrics = nil
          sendMessage(
            type: "lyricsUnavailable",
            line: nil,
            positionMs: Int(player.elapsedTime * 1_000)
          )
          return
        }
        lyrics = loadedLyrics
        currentLineIndex = nil
        updateCurrentLine(positionMs: Int(player.elapsedTime * 1_000), force: true)
      } catch is CancellationError {
        return
      } catch {
        guard song == player.currentlyPlaying?.asSong else { return }
        lyrics = nil
        sendMessage(type: "lyricsUnavailable", line: nil, positionMs: lastPositionMs)
      }
    }
  }

  private func resetTimeline() {
    song = nil
    lyrics = nil
    currentLineIndex = nil
    lastPositionMs = 0
  }

  private func updateCurrentLine(positionMs: Int, force: Bool = false) {
    lastPositionMs = max(positionMs, 0)
    guard let lyrics, lyrics.synced, !lyrics.line.isEmpty else { return }

    let adjustedPosition = lastPositionMs + lyrics.offset
    let newIndex = lyrics.line.lastIndex(where: { line in
      guard let start = line.start else { return false }
      return start <= adjustedPosition
    })
    guard force || newIndex != currentLineIndex else { return }
    currentLineIndex = newIndex
    sendMessage(
      type: "lyrics",
      line: newIndex.flatMap { lyrics.line.object(at: $0) },
      positionMs: lastPositionMs
    )
  }

  private func sendClearMessage() {
    sequence += 1
    transport.send(ExternalLyricsMessage(
      sequence: sequence,
      type: "clear",
      trackId: "",
      title: "",
      artist: "",
      positionMs: 0,
      lineStartMs: 0,
      text: "",
      isPlaying: false
    ))
  }

  private func sendMessage(type: String, line: LyricsLine?, positionMs: Int) {
    guard let song else {
      sendClearMessage()
      return
    }
    sequence += 1
    transport.send(ExternalLyricsMessage(
      sequence: sequence,
      type: type,
      trackId: song.id,
      title: song.title,
      artist: song.creatorName,
      positionMs: positionMs,
      lineStartMs: line?.start ?? 0,
      text: line?.value ?? "",
      isPlaying: isPlaying
    ))
  }

  func didStartPlayingFromBeginning() {
    isPlaying = true
    loadCurrentSong()
  }

  func didStartPlaying() {
    isPlaying = true
    updateCurrentLine(positionMs: Int(player.elapsedTime * 1_000), force: true)
  }

  func didPause() {
    isPlaying = false
    sendMessage(
      type: "state",
      line: currentLineIndex.flatMap { lyrics?.line.object(at: $0) },
      positionMs: lastPositionMs
    )
  }

  func didStopPlaying() {
    isPlaying = false
    loadTask?.cancel()
    resetTimeline()
    sendClearMessage()
  }

  func didElapsedTimeChange() {}

  func didLyricsTimeChange(time: CMTime) {
    updateCurrentLine(positionMs: Int(time.seconds * 1_000))
  }

  func didPlaylistChange() {}
  func didArtworkChange() {}
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
}
