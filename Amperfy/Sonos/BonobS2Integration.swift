//
//  BonobS2Integration.swift
//  Amperfy
//

import AmperfyKit
import Foundation
import MediaPlayer
import UIKit

// MARK: - Learned bonob queue template

/// Sonos embeds the household-specific music-service id, account serial number,
/// and service descriptor in its queue URI/DIDL. Learning one item avoids
/// hard-coding values that differ for every private bonob S2 integration.
struct BonobS2Template: Codable, Sendable {
  let trackURI: String
  let trackMetadata: String
  let learnedTrackID: String

  init(positionInfo: SonosPositionInfo) throws {
    guard let id = Self.trackID(in: positionInfo.trackURI),
          !positionInfo.trackMetadata.isEmpty else {
      throw BonobS2Error.notPlayingBonob
    }
    trackURI = positionInfo.trackURI
    trackMetadata = positionInfo.trackMetadata
    learnedTrackID = id
  }

  func queueItem(for song: Song) throws -> (uri: String, metadata: String) {
    guard !song.id.isEmpty else { throw BonobS2Error.missingSongID }
    let encodedID = song.id.addingPercentEncoding(withAllowedCharacters: .bonobTrackIDAllowed)
      ?? song.id
    let oldEncodedID = learnedTrackID
      .addingPercentEncoding(withAllowedCharacters: .bonobTrackIDAllowed) ?? learnedTrackID

    var uri = trackURI.replacingOccurrences(of: oldEncodedID, with: encodedID)
    if uri == trackURI {
      uri = uri.replacingOccurrences(of: learnedTrackID, with: song.id)
    }
    guard uri != trackURI || learnedTrackID == song.id else {
      throw BonobS2Error.unsupportedTemplate
    }

    var metadata = trackMetadata
      .replacingOccurrences(of: oldEncodedID, with: encodedID)
      .replacingOccurrences(of: learnedTrackID, with: song.id)
    metadata = metadata.replacingXMLValue(of: "dc:title", with: song.title)
    metadata = metadata.replacingXMLValue(of: "dc:creator", with: song.creatorName)
    metadata = metadata.replacingXMLValue(of: "upnp:album", with: song.album?.name ?? "")
    return (uri, metadata)
  }

  static func trackID(in uri: String) -> String? {
    // bonob publishes SMAPI ids as `track:<subsonic-id>`. Sonos percent-encodes
    // the colon in x-sonos-http URIs and may append a decoder file extension.
    let pattern = #"track(?:%3A|:)([^.?&/]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: uri, range: NSRange(uri.startIndex..., in: uri)),
          let range = Range(match.range(at: 1), in: uri) else { return nil }
    let value = String(uri[range])
    return value.removingPercentEncoding ?? value
  }
}

private extension CharacterSet {
  static let bonobTrackIDAllowed = CharacterSet.alphanumerics
    .union(CharacterSet(charactersIn: "-._~"))
}

private extension String {
  func replacingXMLValue(of tag: String, with value: String) -> String {
    let pattern = "(<\(NSRegularExpression.escapedPattern(for: tag))[^>]*>).*?(</\(NSRegularExpression.escapedPattern(for: tag))>)"
    guard let regex = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) else { return self }
    let range = NSRange(startIndex..., in: self)
    let escaped = value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    return regex.stringByReplacingMatches(
      in: self,
      range: range,
      withTemplate: "$1\(NSRegularExpression.escapedTemplate(for: escaped))$2"
    )
  }
}

enum BonobS2Error: LocalizedError {
  case noSongPlaying
  case notPlayingBonob
  case missingSongID
  case unsupportedTemplate
  case noRooms

  var errorDescription: String? {
    switch self {
    case .noSongPlaying: "Select a Subsonic song in Amperfy first."
    case .notPlayingBonob:
      "Play a song from bonob in the Sonos app, then use Learn bonob again."
    case .missingSongID: "The selected song has no Subsonic id."
    case .unsupportedTemplate: "The learned bonob queue format could not be adapted."
    case .noRooms: "No Sonos S2 rooms were found."
    }
  }
}

// MARK: - Playback coordination

@MainActor
final class BonobS2Integration: PlaybackCommandInterceptor, MusicPlayable {
  private enum DefaultsKey {
    static let template = "bonobS2.template"
    static let defaultGroupID = "bonobS2.defaultGroupID"
    static let defaultGroupName = "bonobS2.defaultGroupName"
    static let manualHost = "bonobS2.manualHost"
  }

  private let player: PlayerFacade
  private let controller = SonosLocalController()
  private(set) var isSonosPlaying = false
  private var isSonosPaused = false
  private var activeGroup: SonosGroup?
  private weak var controlButton: UIButton?
  private weak var primaryPlayButton: UIButton?
  private weak var miniPlayerPlayButton: UIButton?
  private weak var playerControlPlayButton: UIButton?
  private weak var miniPlayerTargetButton: UIButton?
  private var bypassingInterception = false
  private var didAttemptStartupRestore = false
  private var isStartupRestoreInProgress = false
  private var suppressStartupRestore = false
  private var startupRestoreAttemptID = 0
  private var sonosElapsedTime = 0.0
  private var sonosDuration = 0.0
  private var sonosPositionSampleDate = Date()
  private var sonosPositionTrackID: String?
  private var sonosVolume: Float?
  private var sonosVolumeChangeGeneration = 0
  private var sonosVolumeSetTask: Task<Void, Never>?
  private var consecutiveSonosSyncFailures = 0
  private var sonosStateSyncTask: Task<Void, Never>?
  private var sonosProgressUpdateTask: Task<Void, Never>?
  private var isSonosAudioSessionActive = false
  private var isPlayPauseCommandInFlight = false
  private var isTrackChangeInFlight = false
  private var trackChangeGeneration = 0
  private var expectedSonosTrackID: String?
  private var acceptTransportConfirmationAfter = Date.distantPast
  private var shouldRestoreWhenLocalNetworkReturns = false
  private weak var startupRestoreAccount: Account?

  init(player: PlayerFacade) {
    self.player = player
    player.setPlaybackCommandInterceptor(self)
    player.addNotifier(notifier: self)
  }

  func interceptPlay() -> Bool {
    preferLocalPlaybackIfNeeded()
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup else { return false }
    return requestSonosPausedState(false, in: group, button: primaryPlayButton)
  }

  func interceptPause() -> Bool {
    preferLocalPlaybackIfNeeded()
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup else { return false }
    return requestSonosPausedState(true, in: group, button: primaryPlayButton)
  }

  func interceptTogglePlayPause() -> Bool {
    preferLocalPlaybackIfNeeded()
    guard isSonosPlaying, !bypassingInterception else { return false }
    return handlePlayPause(button: primaryPlayButton)
  }

  func interceptPrevious() -> Bool {
    preferLocalPlaybackIfNeeded()
    return moveInSonosQueue(next: false)
  }

  func interceptNext() -> Bool {
    preferLocalPlaybackIfNeeded()
    return moveInSonosQueue(next: true)
  }

  func interceptPlay(context: PlayContext, shuffled: Bool) -> Bool {
    preferLocalPlaybackIfNeeded()
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup,
          let template = loadTemplate() else { return false }
    bypassingInterception = true
    player.prepare(context: context, shuffled: shuffled)
    bypassingInterception = false
    resetProjectedSonosPositionForCurrentTrack()
    let keepPlaying = !isSonosPaused
    Task { do { try await transferCurrentQueue(
      to: group, template: template, playAfterTransfer: keepPlaying
    ) }
      catch { presentError(error) }
    }
    return true
  }

  func interceptPlay(playerIndex: PlayerIndex) -> Bool {
    preferLocalPlaybackIfNeeded()
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup,
          let template = loadTemplate() else { return false }
    bypassingInterception = true
    player.prepare(playerIndex: playerIndex)
    bypassingInterception = false
    resetProjectedSonosPositionForCurrentTrack()
    let keepPlaying = !isSonosPaused
    Task { do { try await transferCurrentQueue(
      to: group, template: template, playAfterTransfer: keepPlaying
    ) }
      catch { presentError(error) }
    }
    return true
  }

  func interceptSeek(toSecond: Double) -> Bool {
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup else { return false }
    let duration = resolvedSonosDuration
    let target = max(0, min(toSecond, duration > 0 ? duration : toSecond))
    sonosElapsedTime = target
    sonosPositionSampleDate = Date()
    updateSystemPlaybackState()
    Task {
      do {
        try await controller.seek(in: group, toSecond: target)
        await refreshSonosState()
      } catch {
        presentError(error)
      }
    }
    return true
  }

  func interceptVolumeChange(to volume: Float) -> Bool {
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup else { return false }
    let clampedVolume = min(1, max(0, volume))
    sonosVolume = clampedVolume
    sonosVolumeChangeGeneration += 1
    let generation = sonosVolumeChangeGeneration
    sonosVolumeSetTask?.cancel()
    sonosVolumeSetTask = Task { [weak self] in
      do {
        // A slider can emit dozens of changes per second. Only send the final
        // value after a short quiet period so the group coordinator is not
        // flooded with SetGroupVolume requests.
        try await Task.sleep(for: .milliseconds(150))
        guard let self, isSonosPlaying, activeGroup?.id == group.id,
              generation == sonosVolumeChangeGeneration else { return }
        try await controller.setGroupVolume(
          in: group,
          volume: Int((clampedVolume * 100).rounded())
        )
        guard generation == sonosVolumeChangeGeneration else { return }
        if let confirmedVolume = try? await controller.groupVolume(in: group),
           generation == sonosVolumeChangeGeneration {
          sonosVolume = Float(confirmedVolume) / 100
        }
      } catch is CancellationError {
        // A newer slider value superseded this request.
      } catch {
        guard let self, generation == sonosVolumeChangeGeneration else { return }
        if let confirmedVolume = try? await controller.groupVolume(in: group),
           generation == sonosVolumeChangeGeneration {
          sonosVolume = Float(confirmedVolume) / 100
        }
        // A fixed-volume output or unsupported volume action must not count as
        // a playback connectivity failure and force the app out of Sonos mode.
        presentMessage(title: "Sonos Volume", message: error.localizedDescription)
      }
    }
    return true
  }

  func didStartPlayingFromBeginning() { ensureLocalPlayerIsPaused() }
  func didStartPlaying() { ensureLocalPlayerIsPaused() }
  func didPause() {}
  func didStopPlaying() {}
  func didElapsedTimeChange() {}
  func didLyricsTimeChange(time: CMTime) {}
  func didArtworkChange() {}
  func didNowPlayingInfoChange() {
    // Queue preparation emits this synchronously. The track-change path
    // publishes one coherent Sonos state immediately afterwards.
    guard isSonosPlaying, !bypassingInterception else { return }
    updateSystemPlaybackState()
  }
  func didShuffleChange() {}
  func didRepeatChange() { synchronizeSonosPlayMode() }
  func didPlaybackRateChange() {}

  private func ensureLocalPlayerIsPaused() {
    guard isSonosPlaying, !bypassingInterception, player.isPlaying else { return }
    bypassingInterception = true
    player.pause()
    bypassingInterception = false
    updateSystemPlaybackState()
  }

  func didPlaylistChange() {
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup,
          let template = loadTemplate() else { return }
    Task {
      do { try await transferCurrentQueue(
        to: group, template: template, playAfterTransfer: !isSonosPaused
      ) }
      catch { presentError(error) }
    }
  }

  var hasLearnedTemplate: Bool { loadTemplate() != nil }

  var isPlaybackPlaying: Bool {
    isSonosPlaying ? !isSonosPaused : player.isPlaying
  }

  var isSonosMode: Bool { isSonosPlaying }

  var externalPlaybackElapsedTime: Double? {
    guard isSonosPlaying else { return nil }
    let elapsed = isSonosPaused
      ? sonosElapsedTime
      : sonosElapsedTime + Date().timeIntervalSince(sonosPositionSampleDate)
    let duration = resolvedSonosDuration
    return duration > 0 ? min(elapsed, duration) : elapsed
  }

  var externalPlaybackDuration: Double? {
    guard isSonosPlaying else { return nil }
    return resolvedSonosDuration
  }

  var externalPlaybackVolume: Float? {
    guard isSonosPlaying else { return nil }
    return sonosVolume
  }

  /// Some Sonos/bonob streams report `00:00:00` or `NOT_IMPLEMENTED` as their
  /// duration. The currently matched library item still has the real duration,
  /// which keeps the Sonos progress slider usable without affecting local playback.
  private var resolvedSonosDuration: Double {
    if sonosDuration > 0 { return sonosDuration }
    return Double(player.currentlyPlaying?.duration ?? 0)
  }

  /// Startup restoration is intentionally opportunistic. If the user starts
  /// controlling the local player while discovery is still running, that
  /// explicit choice must win over a late Sonos response.
  private func preferLocalPlaybackIfNeeded() {
    guard !bypassingInterception, !isSonosPlaying else { return }
    suppressStartupRestore = true
    guard isStartupRestoreInProgress else { return }
    startupRestoreAttemptID += 1
    isStartupRestoreInProgress = false
  }

  func restorePlayingSonosIfNeeded(account: Account) {
    startupRestoreAccount = account
    guard !didAttemptStartupRestore, !suppressStartupRestore else { return }
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    didAttemptStartupRestore = true
    guard loadTemplate() != nil,
          let defaultGroupID = UserDefaults.standard.string(forKey: DefaultsKey.defaultGroupID)
    else { return }

    startupRestoreAttemptID += 1
    let attemptID = startupRestoreAttemptID
    isStartupRestoreInProgress = true
    Task {
      defer {
        if startupRestoreAttemptID == attemptID {
          isStartupRestoreInProgress = false
        }
      }
      do {
        let groups = try await controller.refresh(
          manualHost: UserDefaults.standard.string(forKey: DefaultsKey.manualHost)
        )
        let defaultGroupName = UserDefaults.standard.string(forKey: DefaultsKey.defaultGroupName)
        guard let group = groups.first(where: { $0.id == defaultGroupID })
          ?? groups.first(where: { $0.name == defaultGroupName })
        else {
          appDelegate.eventLogger.info(
            topic: "Sonos Restore",
            message: "Saved Sonos room was not found."
          )
          return
        }
        let transport = try await controller.transportInfo(in: group)
        guard transport.isPlaying else {
          appDelegate.eventLogger.info(
            topic: "Sonos Restore",
            message: "Saved Sonos room is not playing (\(transport.state))."
          )
          return
        }
        let position = try await controller.positionInfo(in: group)
        guard let trackID = BonobS2Template.trackID(in: position.trackURI) else {
          appDelegate.eventLogger.info(
            topic: "Sonos Restore",
            message: "The playing Sonos item is not a bonob track."
          )
          return
        }
        guard let song = appDelegate.storage.main.library.getSong(for: account, id: trackID) else {
          appDelegate.eventLogger.info(
            topic: "Sonos Restore",
            message: "The playing bonob track was not found in the active account."
          )
          return
        }

        guard startupRestoreAttemptID == attemptID, !suppressStartupRestore else {
          appDelegate.eventLogger.info(
            topic: "Sonos Restore",
            message: "Restore cancelled because local playback was selected."
          )
          return
        }

        bypassingInterception = true
        player.prepare(
          context: PlayContext(name: "Sonos · \(group.name)", playables: [song]),
          shuffled: false
        )
        bypassingInterception = false
        activeGroup = group
        isSonosPlaying = true
        isSonosPaused = false
        shouldRestoreWhenLocalNetworkReturns = false
        updateSonosPosition(position)
        updateSystemPlaybackState()
        beginSonosStateSynchronization()
        synchronizeSonosPlayMode()
        appDelegate.eventLogger.info(
          topic: "Sonos Restore",
          message: "Restored Sonos playback in \(group.name)."
        )
      } catch {
        // Startup restoration is best-effort. Discovery or a non-bonob source
        // must not interrupt normal app launch.
        appDelegate.eventLogger.info(
          topic: "Sonos Restore",
          message: "Restore skipped: \(error.localizedDescription)"
        )
      }
    }
  }

  func retryStartupRestoreIfPossible() {
    guard !isSonosPlaying, !suppressStartupRestore, let startupRestoreAccount else { return }
    didAttemptStartupRestore = false
    restorePlayingSonosIfNeeded(account: startupRestoreAccount)
  }

  func synchronizeSonosNowPlayingIfNeeded() {
    guard isSonosPlaying else { return }
    beginSonosStateSynchronization()
  }

  func localNetworkDidBecomeAvailable() {
    guard shouldRestoreWhenLocalNetworkReturns, !isSonosPlaying,
          let startupRestoreAccount
    else { return }
    shouldRestoreWhenLocalNetworkReturns = false
    suppressStartupRestore = false
    didAttemptStartupRestore = false
    restorePlayingSonosIfNeeded(account: startupRestoreAccount)
  }

  func registerMiniPlayerPlayButton(_ button: UIButton) {
    miniPlayerPlayButton = button
    refreshRegisteredPlayButtons()
  }

  func registerPlayerControlPlayButton(_ button: UIButton) {
    playerControlPlayButton = button
    refreshRegisteredPlayButtons()
  }

  func registerMiniPlayerTargetButton(_ button: UIButton) {
    miniPlayerTargetButton = button
    refreshSonosButton(button)
  }

  func togglePlaybackTarget(button: UIBarButtonItem) {
    togglePlaybackTarget { [weak self, weak button] in
      guard let self, let button else { return }
      refreshTargetButton(button)
    }
  }

  func togglePlaybackTarget(completion: @escaping () -> Void) {
    if isSonosPlaying {
      leaveSonos(resumeLocally: false, completion: completion)
      return
    }
    Task {
      do {
        let groups = try await controller.refresh(
          manualHost: UserDefaults.standard.string(forKey: DefaultsKey.manualHost)
        )
        guard !groups.isEmpty else { throw BonobS2Error.noRooms }
        let defaultID = UserDefaults.standard.string(forKey: DefaultsKey.defaultGroupID)
        let group = groups.first(where: { $0.id == defaultID }) ?? groups[0]
        try await use(group: group)
        completion()
      } catch {
        presentError(error)
        completion()
      }
    }
  }

  func refreshTargetButton(_ button: UIBarButtonItem) {
    button.tintColor = isSonosPlaying ? .systemBlue : .label
    button.accessibilityLabel = isSonosPlaying
      ? "Switch playback to this device"
      : "Switch playback to Sonos"
  }

  var configuredManualHost: String {
    UserDefaults.standard.string(forKey: DefaultsKey.manualHost) ?? ""
  }

  var configuredDefaultRoomName: String? {
    UserDefaults.standard.string(forKey: DefaultsKey.defaultGroupName)
  }

  func updateManualHost(_ host: String) {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: DefaultsKey.manualHost) }
    else { UserDefaults.standard.set(trimmed, forKey: DefaultsKey.manualHost) }
  }

  func forgetLearnedTemplate() {
    UserDefaults.standard.removeObject(forKey: DefaultsKey.template)
    isSonosPlaying = false
  }

  func clearDefaultRoom() {
    UserDefaults.standard.removeObject(forKey: DefaultsKey.defaultGroupID)
    UserDefaults.standard.removeObject(forKey: DefaultsKey.defaultGroupName)
  }

  func presentControlPanel(from sourceView: UIView, playButton: UIButton? = nil) {
    controlButton = sourceView as? UIButton
    primaryPlayButton = playButton
    let room = activeGroup?.name ?? configuredDefaultRoomName
    let target = isSonosPlaying ? "Sonos · \(room ?? "Selected room")" : "This Device"
    let alert = UIAlertController(
      title: "Playback Target",
      message: "Currently controlling: \(target)",
      preferredStyle: .actionSheet
    )

    if isSonosPlaying {
      alert.addAction(UIAlertAction(
        title: isSonosPaused ? "Resume on Sonos" : "Pause Sonos",
        style: .default
      ) { [weak self] _ in _ = self?.handlePlayPause() })
      alert.addAction(UIAlertAction(title: "Update Sonos Queue", style: .default) {
        [weak self, weak sourceView] _ in
        guard let self, let sourceView else { return }
        beginRoomSelection(from: sourceView)
      })
      alert.addAction(UIAlertAction(title: "Stop Sonos", style: .destructive) {
        [weak self] _ in self?.leaveSonos(resumeLocally: false)
      })
      alert.addAction(UIAlertAction(title: "Switch to This Device", style: .default) {
        [weak self] _ in self?.leaveSonos(resumeLocally: false)
      })
    } else {
      let actionTitle = hasLearnedTemplate ? "Play on Sonos" : "Learn bonob from Sonos"
      alert.addAction(UIAlertAction(title: actionTitle, style: .default) {
        [weak self, weak sourceView] _ in
        guard let self, let sourceView else { return }
        beginRoomSelection(from: sourceView)
      })
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = alert.popoverPresentationController {
      popover.sourceView = sourceView
      popover.sourceRect = sourceView.bounds
    }
    AppDelegate.topViewController()?.present(alert, animated: true)
  }

  private func beginRoomSelection(from sourceView: UIView) {
    Task {
      do {
        let groups = try await controller.refresh(
          manualHost: UserDefaults.standard.string(forKey: DefaultsKey.manualHost)
        )
        guard !groups.isEmpty else { throw BonobS2Error.noRooms }
        if groups.count == 1, let group = groups.first {
          try await use(group: group)
        } else {
          presentRoomPicker(groups: groups, sourceView: sourceView)
        }
      } catch {
        if error is SonosLocalError { presentManualHostPrompt(after: error, sourceView: sourceView) }
        else { presentError(error) }
      }
    }
  }

  private func leaveSonos(resumeLocally: Bool, completion: (() -> Void)? = nil) {
    guard let group = activeGroup else {
      stopControllingSonos()
      if resumeLocally { player.play() }
      completion?()
      return
    }
    Task {
      do { try await controller.pause(in: group) }
      catch { presentError(error) }
      stopControllingSonos()
      if resumeLocally { player.play() }
      completion?()
    }
  }

  private func presentManualHostPrompt(after error: Error, sourceView: UIView) {
    let alert = UIAlertController(
      title: "Sonos not found",
      message: "Enter the local IP address of any Sonos speaker (for example 192.168.1.25).\n\n(error.localizedDescription)",
      preferredStyle: .alert
    )
    alert.addTextField { field in
      field.placeholder = "Sonos IP address"
      field.keyboardType = .numbersAndPunctuation
      field.text = UserDefaults.standard.string(forKey: DefaultsKey.manualHost)
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
      guard let self, let host = alert?.textFields?.first?.text, !host.isEmpty else { return }
      UserDefaults.standard.set(host, forKey: DefaultsKey.manualHost)
      Task {
        do {
          let groups = try await self.controller.refresh(manualHost: host)
          guard !groups.isEmpty else { throw BonobS2Error.noRooms }
          if groups.count == 1, let group = groups.first { try await self.use(group: group) }
          else { self.presentRoomPicker(groups: groups, sourceView: sourceView) }
        } catch {
          UserDefaults.standard.removeObject(forKey: DefaultsKey.manualHost)
          self.presentError(error)
        }
      }
    })
    AppDelegate.topViewController()?.present(alert, animated: true)
  }

  func stopControllingSonos(restoreWhenLocalNetworkReturns: Bool = false) {
    sonosStateSyncTask?.cancel()
    sonosStateSyncTask = nil
    sonosProgressUpdateTask?.cancel()
    sonosProgressUpdateTask = nil
    sonosVolumeSetTask?.cancel()
    sonosVolumeSetTask = nil
    isPlayPauseCommandInFlight = false
    isTrackChangeInFlight = false
    trackChangeGeneration += 1
    expectedSonosTrackID = nil
    acceptTransportConfirmationAfter = .distantPast
    shouldRestoreWhenLocalNetworkReturns = restoreWhenLocalNetworkReturns
    isSonosPlaying = false
    isSonosPaused = false
    activeGroup = nil
    sonosElapsedTime = 0
    sonosDuration = 0
    sonosPositionTrackID = nil
    sonosVolume = nil
    sonosVolumeChangeGeneration += 1
    consecutiveSonosSyncFailures = 0
    deactivateSonosAudioSession()
    let center = MPNowPlayingInfoCenter.default()
    var info = center.nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.elapsedTime
    info[MPMediaItemPropertyPlaybackDuration] = player.duration
    let album = info[MPMediaItemPropertyAlbumTitle] as? String ?? ""
    info[MPMediaItemPropertyAlbumTitle] = album.components(
      separatedBy: " • Sonos · "
    ).first ?? album
    center.nowPlayingInfo = info
    center.playbackState = player.isPlaying ? .playing : .paused
    MPRemoteCommandCenter.shared().changePlaybackRateCommand.isEnabled = true
    NotificationCenter.default.post(
      name: player.isPlaying ? .playerPlay : .playerPause,
      object: self,
      userInfo: nil
    )
    if let controlButton { refreshSonosButton(controlButton) }
    if let miniPlayerTargetButton { refreshSonosButton(miniPlayerTargetButton) }
    if let primaryPlayButton {
      playerHandlerRefreshPlayButton(primaryPlayButton)
    }
    if let miniPlayerPlayButton { playerHandlerRefreshPlayButton(miniPlayerPlayButton) }
    if let playerControlPlayButton { playerHandlerRefreshPlayButton(playerControlPlayButton) }
  }

  func handlePlayPause(button: UIButton? = nil) -> Bool {
    guard isSonosPlaying, let group = activeGroup else { return false }
    return requestSonosPausedState(!isSonosPaused, in: group, button: button)
  }

  private func requestSonosPausedState(
    _ targetPausedState: Bool,
    in group: SonosGroup,
    button: UIButton?
  ) -> Bool {
    guard !isPlayPauseCommandInFlight else { return true }
    isPlayPauseCommandInFlight = true
    let previousPausedState = isSonosPaused
    // Update every registered surface immediately. Sonos confirmation can
    // take noticeable time on a busy Wi-Fi network.
    isSonosPaused = targetPausedState
    acceptTransportConfirmationAfter = Date().addingTimeInterval(2)
    updateSystemPlaybackState()
    Task {
      do {
        if targetPausedState { try await controller.pause(in: group) }
        else { try await controller.play(in: group) }
        isPlayPauseCommandInFlight = false
        guard isSonosPlaying, activeGroup?.id == group.id else { return }
        await refreshSonosState()
        if let button { refreshPlayButton(button) }
        if let primaryPlayButton, primaryPlayButton !== button {
          refreshPlayButton(primaryPlayButton)
        }
      } catch {
        isPlayPauseCommandInFlight = false
        guard isSonosPlaying, activeGroup?.id == group.id else { return }
        isSonosPaused = previousPausedState
        acceptTransportConfirmationAfter = .distantPast
        updateSystemPlaybackState()
        presentError(error)
      }
    }
    return true
  }

  func handleNext() -> Bool {
    moveInSonosQueue(next: true)
  }

  func handlePrevious() -> Bool {
    moveInSonosQueue(next: false)
  }

  private func moveInSonosQueue(next: Bool) -> Bool {
    guard isSonosPlaying, !bypassingInterception, let group = activeGroup else { return false }
    // Do not advance the local queue again until Sonos acknowledges the
    // previous command; otherwise the two queues can diverge on rapid taps.
    guard !isTrackChangeInFlight else { return true }
    let shouldWrapForward = next
      && player.userQueueCount == 0
      && player.nextQueueCount == 0
      && player.prevQueueCount > 0
    let shouldWrapBackward = !next
      && player.userQueueCount == 0
      && player.prevQueueCount == 0
      && player.nextQueueCount > 0
    let shouldWrap = shouldWrapForward || shouldWrapBackward
    let wrapTrackNumber = shouldWrapForward ? 1 : player.nextQueueCount + 1
    trackChangeGeneration += 1
    let commandGeneration = trackChangeGeneration
    isTrackChangeInFlight = true
    bypassingInterception = true
    if shouldWrapForward {
      player.prepare(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    } else if shouldWrapBackward {
      player.prepare(
        playerIndex: PlayerIndex(queueType: .next, index: player.nextQueueCount - 1)
      )
    } else if next {
      player.prepareNext()
    } else {
      player.preparePrevious()
    }
    bypassingInterception = false
    expectedSonosTrackID = player.currentlyPlaying?.id

    // The Amperfy queue has already been copied to Sonos. Moving within it
    // should be a single AVTransport command, not a full remove-and-reinsert
    // of up to 50 tracks. Reset the local projection immediately so the UI
    // reflects the selected song while Sonos handles the command.
    resetProjectedSonosPositionForCurrentTrack()

    Task {
      do {
        if shouldWrap {
          // The wrapped item is already in Sonos' queue. Seeking avoids a full
          // remove-and-reinsert of as many as 50 tracks.
          try await controller.seekTrack(in: group, toNumber: wrapTrackNumber)
        } else if next {
          try await controller.next(in: group)
        } else {
          try await controller.previous(in: group)
        }
        guard commandGeneration == trackChangeGeneration else { return }
        isTrackChangeInFlight = false
        await refreshSonosState()
      } catch {
        guard commandGeneration == trackChangeGeneration else { return }
        isTrackChangeInFlight = false
        expectedSonosTrackID = nil
        // Queue state can differ after another controller edits Sonos. In that
        // exceptional case, restore the known Amperfy queue as a safe fallback.
        guard let template = loadTemplate() else {
          presentError(error)
          return
        }
        do {
          try await transferCurrentQueue(
            to: group, template: template, playAfterTransfer: !isSonosPaused
          )
        } catch {
          presentError(error)
        }
      }
    }
    return true
  }

  func refreshPlayButton(_ button: UIButton) {
    guard isSonosPlaying else { return }
    if button.configuration != nil { button.configuration?.image = isSonosPaused ? .play : .pause }
    else { button.setImage(isSonosPaused ? .play : .pause, for: .normal) }
  }

  func refreshSonosButton(_ button: UIButton) {
    button.tintColor = isSonosPlaying ? .systemBlue : .label
    button.isSelected = isSonosPlaying
    if button.configuration != nil {
      button.configuration?.image = UIImage(
        systemName: isSonosPlaying ? "hifispeaker.2.fill" : "hifispeaker.2"
      )?.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
      button.configuration?.baseForegroundColor = isSonosPlaying ? .systemBlue : .label
    }
    button.accessibilityLabel = isSonosPlaying
      ? "Playback target: Sonos \(activeGroup?.name ?? "")"
      : "Choose Sonos playback target"
  }

  private func beginSonosStateSynchronization() {
    guard isSonosPlaying else { return }
    sonosStateSyncTask?.cancel()
    sonosProgressUpdateTask?.cancel()
    sonosProgressUpdateTask = Task { [weak self] in
      var lastProgressNotification = Date.distantPast
      while !Task.isCancelled {
        guard let self, isSonosPlaying else { return }
        let elapsedTime = externalPlaybackElapsedTime ?? sonosElapsedTime
        let now = Date()
        // The elapsed-time notification also updates system Now Playing data,
        // so sending it at lyric-frame frequency makes track changes visibly
        // stutter. The slider only needs a one-second update; lyrics keep their
        // finer-grained clock below.
        if now.timeIntervalSince(lastProgressNotification) >= 1 {
          player.notifyElapsedTimeChanged()
          lastProgressNotification = now
        }
        player.notifyLyricsTimeChanged(
          time: CMTime(seconds: elapsedTime, preferredTimescale: 600)
        )
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return
        }
      }
    }
    sonosStateSyncTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, isSonosPlaying else { return }
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
           appDelegate.networkMonitor.isCellular {
          leaveUnavailableSonosMode(reason: "The device switched to a cellular network.")
          return
        }
        await refreshSonosState()
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          return
        }
      }
    }
  }

  private func refreshSonosState() async {
    guard isSonosPlaying, !isPlayPauseCommandInFlight, !isTrackChangeInFlight,
          let group = activeGroup else { return }
    let refreshGeneration = trackChangeGeneration
    do {
      let transport = try await controller.transportInfo(in: group)
      let position = try await controller.positionInfo(in: group)
      // Ignore a snapshot started before a Next/Previous command. Without this,
      // a late response can briefly move the UI back to the previous track.
      guard refreshGeneration == trackChangeGeneration,
            isSonosPlaying, !isPlayPauseCommandInFlight, !isTrackChangeInFlight,
            activeGroup?.id == group.id else { return }
      if let expectedSonosTrackID {
        guard BonobS2Template.trackID(in: position.trackURI) == expectedSonosTrackID else {
          // Sonos can acknowledge Next before GetPositionInfo advances. Keep
          // the optimistic UI instead of briefly restoring the previous song.
          return
        }
        self.expectedSonosTrackID = nil
      }
      consecutiveSonosSyncFailures = 0
      if Date() >= acceptTransportConfirmationAfter,
         let confirmedPausedState = transport.isPaused {
        isSonosPaused = confirmedPausedState
      }
      synchronizeCurrentSong(with: position)
      updateSonosPosition(position)
      updateSystemPlaybackState()
      let volumeGeneration = sonosVolumeChangeGeneration
      if let confirmedVolume = try? await controller.groupVolume(in: group),
         volumeGeneration == sonosVolumeChangeGeneration,
         isSonosPlaying, activeGroup?.id == group.id {
        sonosVolume = Float(confirmedVolume) / 100
      }
    } catch {
      guard refreshGeneration == trackChangeGeneration, !isTrackChangeInFlight else { return }
      registerSonosSyncFailure(error)
    }
  }

  private func registerSonosSyncFailure(_ error: Error) {
    guard isSonosPlaying else { return }
    consecutiveSonosSyncFailures += 1
    guard consecutiveSonosSyncFailures >= 2 else { return }
    leaveUnavailableSonosMode(reason: error.localizedDescription)
  }

  private func leaveUnavailableSonosMode(reason: String) {
    guard isSonosPlaying else { return }
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.eventLogger.info(
        topic: "Sonos",
        message: "Switched to This Device because Sonos became unavailable: \(reason)"
      )
    }
    // Keep the local player paused. Losing the home network must never make
    // the phone unexpectedly start playing through its own speaker.
    stopControllingSonos(restoreWhenLocalNetworkReturns: true)
  }

  private func updateSonosPosition(_ position: SonosPositionInfo) {
    let trackID = BonobS2Template.trackID(in: position.trackURI)
    let reportedElapsedTime = Self.timeInterval(fromSonosTime: position.relativeTime) ?? 0
    let projectedElapsedTime = externalPlaybackElapsedTime ?? sonosElapsedTime

    // A position request completes after the value was sampled by Sonos. For
    // the same track it can therefore arrive a second or two behind the UI's
    // projected clock. Never rewind progress/lyrics because of that stale
    // confirmation. A genuinely different track still resets normally.
    if !isSonosPaused, trackID != nil, trackID == sonosPositionTrackID {
      sonosElapsedTime = max(reportedElapsedTime, projectedElapsedTime)
    } else {
      sonosElapsedTime = reportedElapsedTime
    }
    sonosDuration = Self.timeInterval(fromSonosTime: position.duration) ?? 0
    sonosPositionSampleDate = Date()
    sonosPositionTrackID = trackID
  }

  private func resetProjectedSonosPositionForCurrentTrack() {
    sonosElapsedTime = 0
    sonosDuration = 0
    sonosPositionSampleDate = Date()
    sonosPositionTrackID = player.currentlyPlaying?.id
    player.notifyElapsedTimeChanged()
    player.notifyLyricsTimeChanged(time: .zero)
    updateSystemPlaybackState()
  }

  private static func timeInterval(fromSonosTime value: String) -> TimeInterval? {
    let components = value.split(separator: ":").compactMap { Double($0) }
    guard components.count == 3 else { return nil }
    return components[0] * 3600 + components[1] * 60 + components[2]
  }

  private func synchronizeCurrentSong(with position: SonosPositionInfo) {
    guard let trackID = BonobS2Template.trackID(in: position.trackURI),
          player.currentlyPlaying?.id != trackID
    else { return }

    if let index = player.getAllUserQueueItems().firstIndex(where: { $0.id == trackID }) {
      prepareLocally(PlayerIndex(queueType: .user, index: index))
      return
    }
    if let index = player.getAllNextQueueItems().firstIndex(where: { $0.id == trackID }) {
      prepareLocally(PlayerIndex(queueType: .next, index: index))
      return
    }
    if let index = player.getAllPrevQueueItems().firstIndex(where: { $0.id == trackID }) {
      prepareLocally(PlayerIndex(queueType: .prev, index: index))
      return
    }

    guard let account = startupRestoreAccount,
          let appDelegate = UIApplication.shared.delegate as? AppDelegate,
          let song = appDelegate.storage.main.library.getSong(for: account, id: trackID)
    else { return }
    bypassingInterception = true
    player.prepare(
      context: PlayContext(name: "Sonos · \(activeGroup?.name ?? "Sonos")", playables: [song]),
      shuffled: false
    )
    bypassingInterception = false
  }

  private func prepareLocally(_ index: PlayerIndex) {
    bypassingInterception = true
    player.prepare(playerIndex: index)
    bypassingInterception = false
  }

  private func updateSystemPlaybackState() {
    if isSonosPlaying { activateSonosAudioSession() }
    let center = MPNowPlayingInfoCenter.default()
    var info = center.nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyPlaybackRate] = isSonosPaused ? 0.0 : 1.0
    if isSonosPlaying {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = externalPlaybackElapsedTime ?? 0
      info[MPMediaItemPropertyPlaybackDuration] = resolvedSonosDuration
      info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    }

    if let playable = player.currentlyPlaying {
      let trackID = playable.id
      let metadataChanged = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
        != trackID
      info[MPNowPlayingInfoPropertyExternalContentIdentifier] = trackID
      info[MPMediaItemPropertyTitle] = playable.title
      info[MPMediaItemPropertyArtist] = playable.creatorName
      info[MPNowPlayingInfoPropertyMediaType] = NSNumber(
        value: MPNowPlayingInfoMediaType.audio.rawValue
      )
      info[MPMediaItemPropertyIsCloudItem] = !playable.isCached

      let album = playable.asSong?.album?.name ?? ""
      let target = activeGroup?.name ?? configuredDefaultRoomName ?? "Sonos"
      info[MPMediaItemPropertyAlbumTitle] = album.isEmpty
        ? "Sonos · \(target)"
        : "\(album) • Sonos · \(target)"

      // Artwork construction can touch the image cache, so only replace it
      // when the song identifier changes. All other metadata is cheap enough
      // to write atomically with every Sonos state update.
      if metadataChanged, let accountInfo = playable.account?.info,
         let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        let accountSetting = appDelegate.storage.settings.accounts.getSetting(accountInfo).read
        let artworkImage = LibraryEntityImage.getImageToDisplayImmediately(
          libraryEntity: playable,
          themePreference: accountSetting.themePreference,
          artworkDisplayPreference: accountSetting.artworkDisplayPreference,
          useCache: true
        )
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
          boundsSize: artworkImage.size,
          requestHandler: { @Sendable _ in artworkImage }
        )
      }
    }
    center.nowPlayingInfo = info
    center.playbackState = isSonosPaused ? .paused : .playing
    MPRemoteCommandCenter.shared().changePlaybackRateCommand.isEnabled = !isSonosPlaying
    refreshRegisteredPlayButtons()
    if let miniPlayerTargetButton { refreshSonosButton(miniPlayerTargetButton) }
    NotificationCenter.default.post(
      name: isSonosPaused ? .playerPause : .playerPlay,
      object: self,
      userInfo: nil
    )
  }

  private func refreshRegisteredPlayButtons() {
    if let miniPlayerPlayButton { refreshPlayButton(miniPlayerPlayButton) }
    if let playerControlPlayButton { refreshPlayButton(playerControlPlayButton) }
  }

  private func activateSonosAudioSession() {
    guard !isSonosAudioSessionActive else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback)
      try session.setActive(true)
      isSonosAudioSessionActive = true
    } catch {
      if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        appDelegate.eventLogger.report(topic: "Sonos Audio Session", error: error)
      }
    }
  }

  private func deactivateSonosAudioSession() {
    guard isSonosAudioSessionActive else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    } catch {
      if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        appDelegate.eventLogger.report(topic: "Sonos Audio Session", error: error)
      }
    }
    isSonosAudioSessionActive = false
  }

  private func synchronizeSonosPlayMode() {
    guard isSonosPlaying, let group = activeGroup else { return }
    let mode: String = switch player.repeatMode {
    case .off: "NORMAL"
    case .all: "REPEAT_ALL"
    case .single: "REPEAT_ONE"
    }
    Task {
      do {
        try await controller.setPlayMode(in: group, mode: mode)
      } catch {
        presentError(error)
      }
    }
  }

  /// iOS does not guarantee execution after the user terminates the process,
  /// but issuing Pause here covers termination paths where a final grace period
  /// is provided. The Sonos state is updated optimistically before the request.
  func pauseForApplicationTermination() {
    guard isSonosPlaying, !isSonosPaused, let group = activeGroup else { return }
    isSonosPaused = true
    updateSystemPlaybackState()
    Task { try? await controller.pause(in: group) }
  }

  private func use(group: SonosGroup) async throws {
    UserDefaults.standard.set(group.id, forKey: DefaultsKey.defaultGroupID)
    UserDefaults.standard.set(group.name, forKey: DefaultsKey.defaultGroupName)
    guard let template = loadTemplate() else {
      let position = try await controller.positionInfo(in: group)
      let learned = try BonobS2Template(positionInfo: position)
      try saveTemplate(learned)
      presentMessage(
        title: "bonob learned",
        message: "Amperfy learned the bonob queue format from \(group.name). Tap the speaker button again to play the Amperfy queue."
      )
      return
    }
    // Changing the playback target is a deliberate mode switch. Prepare the
    // Sonos queue but wait for an explicit Play command.
    try await transferCurrentQueue(to: group, template: template, playAfterTransfer: false)
  }

  private func transferCurrentQueue(
    to group: SonosGroup,
    template: BonobS2Template,
    playAfterTransfer: Bool
  ) async throws {
    guard let current = player.currentlyPlaying?.asSong else {
      throw BonobS2Error.noSongPlaying
    }
    let accountID = current.account?.id
    let candidates = [current]
      + player.getAllUserQueueItems().compactMap(\.asSong)
      + player.getAllNextQueueItems().compactMap(\.asSong)
    let songs = Array(candidates.filter { $0.account?.id == accountID }.prefix(50))
    let items = try songs.map { try template.queueItem(for: $0) }
    let wasPlaying = player.isPlaying
    bypassingInterception = true
    player.pause()
    bypassingInterception = false
    do {
      try await controller.replaceQueue(
        in: group, items: items, playAfterTransfer: playAfterTransfer
      )
      let playMode: String = switch player.repeatMode {
      case .off: "NORMAL"
      case .all: "REPEAT_ALL"
      case .single: "REPEAT_ONE"
      }
      // Queue transfer is still valid if an older renderer rejects the play
      // mode command. Do not resume the local speaker after Sonos has already
      // accepted and possibly started the new queue.
      try? await controller.setPlayMode(in: group, mode: playMode)
      isSonosPlaying = true
      isSonosPaused = !playAfterTransfer
      activeGroup = group
      // Close the handoff race where local playback can finish starting while
      // the Sonos queue request is still in flight.
      ensureLocalPlayerIsPaused()
      updateSystemPlaybackState()
      beginSonosStateSynchronization()
      if let controlButton { refreshSonosButton(controlButton) }
      if let primaryPlayButton { refreshPlayButton(primaryPlayButton) }
    } catch {
      if wasPlaying { player.play() }
      throw error
    }
  }

  private func presentRoomPicker(groups: [SonosGroup], sourceView: UIView) {
    let alert = UIAlertController(title: "Play on Sonos", message: nil, preferredStyle: .actionSheet)
    let defaultID = UserDefaults.standard.string(forKey: DefaultsKey.defaultGroupID)
    for group in groups.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
      let suffix = group.id == defaultID ? " ✓" : ""
      alert.addAction(UIAlertAction(title: group.name + suffix, style: .default) { [weak self] _ in
        guard let self else { return }
        Task {
          do { try await self.use(group: group) }
          catch { self.presentError(error) }
        }
      })
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = alert.popoverPresentationController {
      popover.sourceView = sourceView
      popover.sourceRect = sourceView.bounds
    }
    AppDelegate.topViewController()?.present(alert, animated: true)
  }

  private func playerHandlerRefreshPlayButton(_ button: UIButton) {
    if button.configuration != nil { button.configuration?.image = player.isPlaying ? .pause : .play }
    else { button.setImage(player.isPlaying ? .pause : .play, for: .normal) }
  }

  private func loadTemplate() -> BonobS2Template? {
    guard let data = UserDefaults.standard.data(forKey: DefaultsKey.template) else { return nil }
    return try? JSONDecoder().decode(BonobS2Template.self, from: data)
  }

  private func saveTemplate(_ template: BonobS2Template) throws {
    UserDefaults.standard.set(try JSONEncoder().encode(template), forKey: DefaultsKey.template)
  }

  private func presentError(_ error: Error) {
    registerSonosSyncFailure(error)
    presentMessage(title: "Sonos", message: error.localizedDescription)
  }

  private func presentMessage(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    AppDelegate.topViewController()?.present(alert, animated: true)
  }
}
