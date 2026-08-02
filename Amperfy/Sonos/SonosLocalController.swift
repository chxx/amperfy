//
//  SonosLocalController.swift
//  Amperfy
//
//  Local Sonos S2 control used by the optional bonob integration.
//

import Foundation
import Network

// MARK: - Models

struct SonosDevice: Hashable, Identifiable, Sendable {
  let id: String
  let roomName: String
  let location: URL

  var baseURL: URL {
    var components = URLComponents(url: location, resolvingAgainstBaseURL: false)!
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url!
  }
}

struct SonosGroup: Hashable, Identifiable, Sendable {
  let id: String
  let coordinatorID: String
  let name: String
  let memberIDs: [String]
}

struct SonosPositionInfo: Sendable {
  let track: Int
  let trackURI: String
  let trackMetadata: String
  let relativeTime: String
  let duration: String
}

struct SonosTransportInfo: Sendable {
  let state: String

  var isPlaying: Bool {
    state.caseInsensitiveCompare("PLAYING") == .orderedSame
  }

  var isPaused: Bool? {
    switch state.uppercased() {
    case "PLAYING": false
    case "PAUSED_PLAYBACK", "STOPPED": true
    default: nil // Keep the optimistic UI state while Sonos is transitioning.
    }
  }
}

enum SonosLocalError: LocalizedError {
  case discoveryTimedOut
  case invalidDeviceDescription
  case noCoordinator
  case invalidResponse
  case soapFault(action: String, code: String, description: String)

  var errorDescription: String? {
    switch self {
    case .discoveryTimedOut: "No Sonos S2 speakers were found on the local network."
    case .invalidDeviceDescription: "A Sonos speaker returned an invalid device description."
    case .noCoordinator: "The selected Sonos group has no available coordinator."
    case .invalidResponse: "The Sonos speaker returned an invalid response."
    case let .soapFault(action, code, description):
      "Sonos \(action) error \(code): \(Self.knownDescription(code) ?? description)"
    }
  }

  private static func knownDescription(_ code: String) -> String? {
    switch code {
    case "714": "Illegal MIME type"
    default: nil
    }
  }
}

// MARK: - SSDP

/// Uses Sonos' advertised Bonjour service on iOS, avoiding the restricted
/// multicast entitlement required by raw SSDP on physical devices.
final class SonosBonjourDiscovery: @unchecked Sendable {
  func discover(timeout: Duration = .seconds(3)) async throws -> [URL] {
    try await withCheckedThrowingContinuation { continuation in
      let session = SonosBonjourSession(continuation: continuation)
      session.start(timeout: timeout.timeInterval)
    }
  }
}

private final class SonosBonjourSession: @unchecked Sendable {
  private let continuation: CheckedContinuation<[URL], Error>
  private let queue = DispatchQueue(label: "de.amperfy.sonos.bonjour")
  private let lock = NSLock()
  private let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: .tcp)
  private var resolvers = [NWEndpoint: NWConnection]()
  private var locations = Set<URL>()
  private var isFinished = false

  init(continuation: CheckedContinuation<[URL], Error>) {
    self.continuation = continuation
  }

  func start(timeout: TimeInterval) {
    browser.stateUpdateHandler = { [self] state in
      if case let .failed(error) = state { finish(.failure(error)) }
    }
    browser.browseResultsChangedHandler = { [self] results, _ in
      for result in results { resolve(result.endpoint) }
    }
    browser.start(queue: queue)
    queue.asyncAfter(deadline: .now() + timeout) { [self] in finishDiscovery() }
  }

  private func resolve(_ endpoint: NWEndpoint) {
    guard lock.withLock({ !isFinished && resolvers[endpoint] == nil }) else { return }
    let connection = NWConnection(to: endpoint, using: .tcp)
    lock.withLock { resolvers[endpoint] = connection }
    connection.stateUpdateHandler = { [self, weak connection] state in
      guard let connection else { return }
      switch state {
      case .ready:
        if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
          var components = URLComponents()
          components.scheme = "http"
          components.host = String(describing: host)
          components.port = Int(port.rawValue)
          components.path = "/xml/device_description.xml"
          if let url = components.url { lock.withLock { _ = locations.insert(url) } }
        }
        stopResolver(endpoint, connection: connection)
      case .failed, .cancelled:
        stopResolver(endpoint, connection: connection)
      default: break
      }
    }
    connection.start(queue: queue)
  }

  private func stopResolver(_ endpoint: NWEndpoint, connection: NWConnection) {
    connection.stateUpdateHandler = nil
    connection.cancel()
    lock.withLock { _ = resolvers.removeValue(forKey: endpoint) }
  }

  private func finishDiscovery() {
    let found = lock.withLock { locations.sorted { $0.absoluteString < $1.absoluteString } }
    finish(found.isEmpty ? .failure(SonosLocalError.discoveryTimedOut) : .success(found))
  }

  private func finish(_ result: Result<[URL], Error>) {
    let activeResolvers: [NWConnection]? = lock.withLock {
      guard !isFinished else { return nil }
      isFinished = true
      let active = Array(resolvers.values)
      resolvers.removeAll()
      return active
    }
    guard let activeResolvers else { return }
    browser.stateUpdateHandler = nil
    browser.browseResultsChangedHandler = nil
    browser.cancel()
    for connection in activeResolvers {
      connection.stateUpdateHandler = nil
      connection.cancel()
    }
    continuation.resume(with: result)
  }
}

/// Discovers ZonePlayers using the standard Sonos/UPnP SSDP target.
final class SonosSSDPDiscovery: @unchecked Sendable {
  private static let multicastHost = NWEndpoint.Host("239.255.255.250")
  private static let multicastPort = NWEndpoint.Port(rawValue: 1900)!

  func discover(timeout: Duration = .seconds(3)) async throws -> [URL] {
    try await withCheckedThrowingContinuation { continuation in
      let connection = NWConnection(
        host: Self.multicastHost,
        port: Self.multicastPort,
        using: .udp
      )
      let session = SonosSSDPSession(connection: connection, continuation: continuation)
      session.start(timeout: timeout.timeInterval)
    }
  }
}

private final class SonosSSDPSession: @unchecked Sendable {
  private let connection: NWConnection
  private let continuation: CheckedContinuation<[URL], Error>
  private let queue = DispatchQueue(label: "de.amperfy.sonos.ssdp")
  private let lock = NSLock()
  private var locations = Set<URL>()
  private var isFinished = false

  init(connection: NWConnection, continuation: CheckedContinuation<[URL], Error>) {
    self.connection = connection
    self.continuation = continuation
  }

  func start(timeout: TimeInterval) {
    // NWConnection retains its handlers. Keep this session alive until finish()
    // resumes the continuation, then break the cycle there.
    connection.stateUpdateHandler = { [self] state in handle(state) }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + timeout) { [self] in finishDiscovery() }
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready:
      let request = [
        "M-SEARCH * HTTP/1.1", "HOST: 239.255.255.250:1900",
        "MAN: \"ssdp:discover\"", "MX: 2",
        "ST: urn:schemas-upnp-org:device:ZonePlayer:1", "", "",
      ].joined(separator: "\r\n")
      connection.send(content: request.data(using: .utf8), completion: .contentProcessed {
        [weak self] error in
        if let error { self?.finish(.failure(error)) }
      })
      receiveNext()
    case let .failed(error): finish(.failure(error))
    default: break
    }
  }

  private func receiveNext() {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self else { return }
      if let data, let response = String(data: data, encoding: .utf8) {
        lock.withLock {
          for line in response.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                 .caseInsensitiveCompare("location") == .orderedSame,
               let url = URL(string: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
              locations.insert(url)
            }
          }
        }
      }
      if error == nil, !lock.withLock({ isFinished }) { receiveNext() }
    }
  }

  private func finishDiscovery() {
    let found = lock.withLock { locations.sorted { $0.absoluteString < $1.absoluteString } }
    finish(found.isEmpty ? .failure(SonosLocalError.discoveryTimedOut) : .success(found))
  }

  private func finish(_ result: Result<[URL], Error>) {
    let shouldFinish = lock.withLock {
      guard !isFinished else { return false }
      isFinished = true
      return true
    }
    guard shouldFinish else { return }
    connection.stateUpdateHandler = nil
    connection.cancel()
    continuation.resume(with: result)
  }
}

private extension Duration {
  var timeInterval: TimeInterval {
    let parts = components
    return Double(parts.seconds) + (Double(parts.attoseconds) / 1e18)
  }
}

// MARK: - XML helpers

private final class ElementValueParser: NSObject, XMLParserDelegate {
  private(set) var values = [String: String]()
  private var currentElement: String?
  private var currentText = ""

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName
    currentText = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if currentElement == elementName {
      values[elementName] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    currentElement = nil
    currentText = ""
  }
}

private final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
  private var currentElement = ""
  private var currentText = ""
  private(set) var roomName: String?
  private(set) var udn: String?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName
    currentText = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentText += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    if elementName == "roomName" { roomName = value }
    if elementName == "UDN" { udn = value.replacingOccurrences(of: "uuid:", with: "") }
    currentElement = ""
    currentText = ""
  }
}

private final class ZoneGroupParser: NSObject, XMLParserDelegate {
  private(set) var groups = [SonosGroup]()
  private(set) var memberLocations = [String: URL]()
  private var groupID: String?
  private var coordinatorID: String?
  private var groupName: String?
  private var memberIDs = [String]()

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes: [String: String] = [:]
  ) {
    switch elementName {
    case "ZoneGroup":
      groupID = attributes["ID"]
      coordinatorID = attributes["Coordinator"]
      memberIDs = []
      groupName = nil
    case "ZoneGroupMember":
      if let uuid = attributes["UUID"] {
        memberIDs.append(uuid)
        if let value = attributes["Location"], let url = URL(string: value) {
          memberLocations[uuid] = url
        }
      }
      if groupName == nil { groupName = attributes["ZoneName"] }
    default:
      break
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "ZoneGroup", let groupID, let coordinatorID {
      groups.append(SonosGroup(
        id: groupID,
        coordinatorID: coordinatorID,
        name: groupName ?? "Sonos",
        memberIDs: memberIDs
      ))
    }
  }
}

// MARK: - SOAP

private struct SonosSOAPClient: Sendable {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func call(
    device: SonosDevice,
    path: String,
    service: String,
    action: String,
    arguments: [(String, String)] = []
  ) async throws -> [String: String] {
    guard let url = URL(string: path, relativeTo: device.baseURL) else {
      throw SonosLocalError.invalidResponse
    }
    let bodyArguments = arguments.map {
      "<\($0.0)>\($0.1.xmlEscaped)</\($0.0)>"
    }.joined()
    let envelope = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
      <s:Body><u:\(action) xmlns:u="\(service)">\(bodyArguments)</u:\(action)></s:Body>
    </s:Envelope>
    """
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = envelope.data(using: .utf8)
    request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
    request.timeoutInterval = 8

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SonosLocalError.invalidResponse
    }
    let parserDelegate = ElementValueParser()
    let parser = XMLParser(data: data)
    parser.delegate = parserDelegate
    _ = parser.parse()
    if !(200 ... 299).contains(http.statusCode) {
      throw SonosLocalError.soapFault(
        action: action,
        code: parserDelegate.values["errorCode"] ?? String(http.statusCode),
        description: parserDelegate.values["errorDescription"] ?? "Unknown error"
      )
    }
    return parserDelegate.values
  }
}

private extension String {
  var xmlEscaped: String {
    replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

// MARK: - Controller

actor SonosLocalController {
  private let bonjourDiscovery = SonosBonjourDiscovery()
  private let discovery = SonosSSDPDiscovery()
  private let soap = SonosSOAPClient()
  private(set) var devices = [String: SonosDevice]()
  private(set) var groups = [SonosGroup]()

  private static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
  private static let topology = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
  private static let groupRenderingControl =
    "urn:schemas-upnp-org:service:GroupRenderingControl:1"

  func refresh(manualHost: String? = nil) async throws -> [SonosGroup] {
    let locations: [URL]
    if let manualHost, let location = deviceDescriptionURL(host: manualHost) {
      locations = [location]
    } else {
      do {
        locations = try await bonjourDiscovery.discover()
      } catch {
        // Useful on macOS and on builds provisioned with Apple's multicast
        // entitlement; physical iOS devices normally succeed through Bonjour.
        locations = try await discovery.discover()
      }
    }
    var discovered = [String: SonosDevice]()
    for location in locations {
      if let device = try? await loadDevice(at: location) {
        discovered[device.id] = device
      }
    }
    guard let seed = discovered.values.first else {
      throw SonosLocalError.discoveryTimedOut
    }
    devices = discovered
    let values = try await soap.call(
      device: seed,
      path: "/ZoneGroupTopology/Control",
      service: Self.topology,
      action: "GetZoneGroupState"
    )
    guard let zoneGroupState = values["ZoneGroupState"],
          let data = zoneGroupState.data(using: .utf8) else {
      throw SonosLocalError.invalidResponse
    }
    let delegate = ZoneGroupParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { throw SonosLocalError.invalidResponse }
    for (id, location) in delegate.memberLocations where discovered[id] == nil {
      if let device = try? await loadDevice(at: location) { discovered[id] = device }
    }
    devices = discovered
    groups = delegate.groups
    return groups
  }

  private func deviceDescriptionURL(host: String) -> URL? {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if let supplied = URL(string: trimmed), supplied.scheme != nil {
      var components = URLComponents(url: supplied, resolvingAgainstBaseURL: false)
      if components?.port == nil { components?.port = 1400 }
      components?.path = "/xml/device_description.xml"
      components?.query = nil
      components?.fragment = nil
      return components?.url
    }
    var components = URLComponents()
    components.scheme = "http"
    components.host = trimmed
    components.port = 1400
    components.path = "/xml/device_description.xml"
    return components.url
  }

  func coordinator(for group: SonosGroup) throws -> SonosDevice {
    guard let device = devices[group.coordinatorID] else {
      throw SonosLocalError.noCoordinator
    }
    return device
  }

  /// Quickly validates the previously discovered household player without
  /// waiting for a full Bonjour/SSDP discovery cycle.
  func isKnownPlayerReachable(id: String, timeout: TimeInterval = 1) async -> Bool {
    guard let location = devices[id]?.location else { return false }
    do {
      return try await loadDevice(at: location, timeout: timeout).id == id
    } catch {
      return false
    }
  }

  func positionInfo(in group: SonosGroup) async throws -> SonosPositionInfo {
    let device = try coordinator(for: group)
    let values = try await avTransportCall(device, action: "GetPositionInfo")
    return SonosPositionInfo(
      track: Int(values["Track"] ?? "0") ?? 0,
      trackURI: values["TrackURI"] ?? "",
      trackMetadata: values["TrackMetaData"] ?? "",
      relativeTime: values["RelTime"] ?? "00:00:00",
      duration: values["TrackDuration"] ?? "00:00:00"
    )
  }

  func transportInfo(in group: SonosGroup) async throws -> SonosTransportInfo {
    let device = try coordinator(for: group)
    let values = try await avTransportCall(device, action: "GetTransportInfo")
    return SonosTransportInfo(state: values["CurrentTransportState"] ?? "")
  }

  func play(in group: SonosGroup) async throws {
    let device = try coordinator(for: group)
    _ = try await avTransportCall(device, action: "Play", arguments: [("Speed", "1")])
  }

  func pause(in group: SonosGroup) async throws {
    let device = try coordinator(for: group)
    _ = try await avTransportCall(device, action: "Pause")
  }

  func next(in group: SonosGroup) async throws {
    let device = try coordinator(for: group)
    _ = try await avTransportCall(device, action: "Next")
  }

  func previous(in group: SonosGroup) async throws {
    let device = try coordinator(for: group)
    _ = try await avTransportCall(device, action: "Previous")
  }

  func seekTrack(in group: SonosGroup, toNumber trackNumber: Int) async throws {
    let device = try coordinator(for: group)
    _ = try await avTransportCall(
      device,
      action: "Seek",
      arguments: [
        ("Unit", "TRACK_NR"),
        ("Target", String(max(1, trackNumber))),
      ]
    )
  }

  func groupVolume(in group: SonosGroup) async throws -> Int {
    let device = try coordinator(for: group)
    let values = try await soap.call(
      device: device,
      path: "/MediaRenderer/GroupRenderingControl/Control",
      service: Self.groupRenderingControl,
      action: "GetGroupVolume",
      arguments: [("InstanceID", "0")]
    )
    guard let value = values["CurrentVolume"], let volume = Int(value) else {
      throw SonosLocalError.invalidResponse
    }
    return min(100, max(0, volume))
  }

  func setGroupVolume(in group: SonosGroup, volume: Int) async throws {
    let device = try coordinator(for: group)
    _ = try await soap.call(
      device: device,
      path: "/MediaRenderer/GroupRenderingControl/Control",
      service: Self.groupRenderingControl,
      action: "SetGroupVolume",
      arguments: [
        ("InstanceID", "0"),
        ("DesiredVolume", String(min(100, max(0, volume)))),
      ]
    )
  }

  func setPlayMode(in group: SonosGroup, mode: String) async throws {
    let device = try coordinator(for: group)
    _ = try await avTransportCall(
      device,
      action: "SetPlayMode",
      arguments: [("NewPlayMode", mode)]
    )
  }

  func seek(in group: SonosGroup, toSecond: Double) async throws {
    let device = try coordinator(for: group)
    let totalSeconds = max(0, Int(toSecond.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    let target = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    _ = try await avTransportCall(
      device,
      action: "Seek",
      arguments: [("Unit", "REL_TIME"), ("Target", target)]
    )
  }

  func replaceQueue(
    in group: SonosGroup,
    items: [(uri: String, metadata: String)],
    startAt index: Int = 0,
    playAfterTransfer: Bool
  ) async throws {
    guard !items.isEmpty else { return }
    let device = try coordinator(for: group)
    let mediaInfo = try await avTransportCall(device, action: "GetMediaInfo")
    let existingTransportURI = mediaInfo["CurrentURI"] ?? ""
    _ = try await avTransportCall(device, action: "RemoveAllTracksFromQueue")
    for item in items {
      _ = try await avTransportCall(
        device,
        action: "AddURIToQueue",
        arguments: [
          ("EnqueuedURI", item.uri),
          ("EnqueuedURIMetaData", item.metadata),
          ("DesiredFirstTrackNumberEnqueued", "0"),
          ("EnqueueAsNext", "0"),
        ]
      )
    }
    // A track started from bonob in the Sonos app is normally already backed by
    // the household queue. Keep Sonos' own queue URI instead of guessing its
    // model/household-specific form. Only switch when the active source is not
    // a queue at all.
    if !existingTransportURI.lowercased().hasPrefix("x-rincon-queue:") {
      _ = try await avTransportCall(
        device,
        action: "SetAVTransportURI",
        arguments: [
          ("CurrentURI", "x-rincon-queue:\(device.id)#0"),
          ("CurrentURIMetaData", ""),
        ]
      )
    }
    _ = try await avTransportCall(
      device,
      action: "Seek",
      arguments: [("Unit", "TRACK_NR"), ("Target", String(index + 1))]
    )
    if playAfterTransfer {
      _ = try await avTransportCall(device, action: "Play", arguments: [("Speed", "1")])
    } else {
      // Pause is intentionally best-effort because a stopped/already-paused
      // renderer may reject Pause even though the requested state is achieved.
      _ = try? await avTransportCall(device, action: "Pause")
    }
  }

  private func loadDevice(
    at location: URL,
    timeout: TimeInterval = 8
  ) async throws -> SonosDevice {
    var request = URLRequest(url: location)
    request.timeoutInterval = timeout
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw SonosLocalError.invalidDeviceDescription
    }
    let delegate = DeviceDescriptionParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), let id = delegate.udn, let roomName = delegate.roomName else {
      throw SonosLocalError.invalidDeviceDescription
    }
    return SonosDevice(id: id, roomName: roomName, location: location)
  }

  private func avTransportCall(
    _ device: SonosDevice,
    action: String,
    arguments: [(String, String)] = []
  ) async throws -> [String: String] {
    try await soap.call(
      device: device,
      path: "/MediaRenderer/AVTransport/Control",
      service: Self.avTransport,
      action: action,
      arguments: [("InstanceID", "0")] + arguments
    )
  }
}
