//
//  QuickPicksView.swift — Picks tab: personal parlay builder.
//
//  Add picks by tapping a game on the Schedule tab → Game Picks page.
//

import SwiftUI
import Photos
import Combine

struct PickTrackingState {
    let statusText: String
    let scoreText: String?
    let currentValue: Double?
    let isLive: Bool
    let isFinal: Bool
}

private struct TrackerRow: Identifiable {
    let id: String
    let playerName: String
    let teamAbbrev: String
    let gameLabel: String
    let statusText: String
    let currentValue: Double
    let targetValue: Int
    let targetLabel: String
    let isPositive: Bool
    let isFinal: Bool
}

// MARK: - ParlayBuilderView

struct QuickPicksView: View {

    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var dataService = LocalDataService.shared
    @State private var isSavingScreenshot = false
    @State private var screenshotMessage: String? = nil
    @State private var simParlayProb: Double? = nil
    @State private var trackingByPickID: [String: PickTrackingState] = [:]
    @State private var trackerRows: [TrackerRow] = []
    @State private var showAddPlayerSheet = false
    private let liveTicker = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

    private var correlationWarning: String? {
        let picks = router.parlayPicks
        guard picks.count >= 2 else { return nil }

        let byGame = Dictionary(grouping: picks, by: { $0.gameID ?? "" })
            .filter { !$0.key.isEmpty && $0.value.count >= 2 }
        guard !byGame.isEmpty else { return nil }

        let maxSameGame = byGame.values.map(\.count).max() ?? 0
        let sameStatPair = byGame.values.contains { group in
            let labels = group.map(\.statLabel)
            return Set(labels).count < labels.count
        }

        if maxSameGame >= 3 || sameStatPair {
            return "High correlation risk: multiple same-game legs can swing together."
        }
        return "Moderate correlation: same-game legs are not independent."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                if router.parlayPicks.isEmpty {
                    emptyState
                } else {
                    parlayList
                }
            }
            .navigationTitle("My Picks")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarItems }
            .sheet(isPresented: $showAddPlayerSheet) {
                TrackerPlayerPickerView(
                    players: dataService.snapshot?.players ?? [],
                    onAdd: { player, target in
                        let tracked = TrackedPlayer(
                            name: player.name,
                            teamAbbrev: (player.team ?? "").uppercased(),
                            targetStat: target.stat,
                            targetValue: target.value
                        )
                        router.addTrackedPlayer(tracked)
                    }
                )
            }
            .alert(screenshotMessage ?? "", isPresented: Binding(
                get: { screenshotMessage != nil },
                set: { if !$0 { screenshotMessage = nil } }
            )) {
                Button("OK", role: .cancel) { screenshotMessage = nil }
            }
            .task { await computeSimProb() }
            .onChange(of: router.parlayPicks.count) { _, _ in Task { await computeSimProb() } }
            .task { await refreshTrackedPicks() }
            .onChange(of: router.trackedPlayers) { _, _ in Task { await refreshTrackedPicks() } }
            .onChange(of: router.parlayPicks) { _, _ in Task { await refreshTrackedPicks() } }
            .onChange(of: dataService.snapshotID) { _, _ in
                router.pruneCompletedPicks()
                Task { await refreshTrackedPicks() }
            }
            .onChange(of: dataService.logsRevision) { _, _ in
                Task {
                    await computeSimProb()
                    await refreshTrackedPicks()
                }
            }
            .onReceive(dataService.$gameDetails) { _ in
                router.pruneCompletedPicks()
                Task { await refreshTrackedPicks() }
            }
            .onReceive(liveTicker) { _ in
                Task { await refreshTrackedPicks() }
            }
            .task {
                router.pruneCompletedPicks()
            }
        }
    }

    // MARK: - Parlay list

    private var parlayList: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Probability summary card
                summaryCard
                trackerCard

                // Picks
                VStack(spacing: 10) {
                    ForEach(router.parlayPicks) { pick in
                        ParlayPickRow(pick: pick, tracking: trackingByPickID[pick.id])
                    }
                }
                .padding(.horizontal, 16)

                // Clear button
                Button(role: .destructive) {
                    withAnimation { router.clearParlay() }
                } label: {
                    Label("Clear All Picks", systemImage: "trash")
                        .font(.subheadline.bold())
                        .foregroundColor(.red.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red.opacity(0.25), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(router.parlayPicks.count) picks")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    Text(simParlayProb != nil ? "Monte Carlo · \(SimulationEngine.defaultSimulationCount) simulations" : "Combined probability")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                Text(combinedProbString)
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundColor(combinedProbColor)
            }

            if let warning = correlationWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange.opacity(0.85))
                        .padding(.top, 2)
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.65))
                    Spacer()
                }
            }


        }
        .padding(16)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.skyBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var combinedProbString: String {
        let p = simParlayProb ?? router.combinedProbability
        if p <= 0 { return "—" }
        return "\(Int(round(p * 100)))%"
    }

    private var combinedProbColor: Color {
        let p = simParlayProb ?? router.combinedProbability
        if p >= 0.50 { return .green }
        if p >= 0.30 { return .skyBright }
        return .orange
    }

    // MARK: - A. Play Tracker

    private var trackerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundColor(.skyBright)
                Text("A. Play Tracker")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Spacer()
                Button {
                    showAddPlayerSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.skyBright)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await refreshTrackedPicks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.skyBright)
                }
                .buttonStyle(.plain)
            }

            if trackerRows.isEmpty {
                Text("Add players here or add props in game picks. We will track their live game progress.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
            } else {
                VStack(spacing: 8) {
                    ForEach(trackerRows) { row in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(row.isPositive ? .green : (row.isFinal ? .orange : .skyBright))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.playerName)
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                Text("\(row.teamAbbrev)  •  \(row.gameLabel)")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.45))
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(row.statusText)
                                    .font(.caption.bold())
                                    .foregroundColor(row.isPositive ? .green : (row.isFinal ? .orange : .skyBright))
                                Text("\(row.currentValue.cleanLine) / \(row.targetValue) \(row.targetLabel)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.white.opacity(0.72))
                            }

                            Button {
                                router.removeTrackedPlayer(idKey: row.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.skyBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Monte Carlo parlay simulation

    /// Runs 500-trial Monte Carlo to compute a correlated parlay probability.
    /// Falls back to simple multiplication when player logs are unavailable.
    private func computeSimProb() async {
        let picks = router.parlayPicks
        guard !picks.isEmpty else { simParlayProb = nil; return }

        let players     = dataService.snapshot?.players ?? []
        let games       = dataService.snapshot?.games ?? []

        var logsByName: [String: [GameLog]] = [:]
        for pick in picks {
            if let player = players.first(where: { $0.name == pick.playerName }) {
                logsByName[pick.playerName] = dataService.localLogs(playerID: player.playerID)
            }
        }

        // Build gamesByID mapping for opponent context in simulation
        var gamesByID: [String: ScheduleGame] = [:]
        for game in games {
            gamesByID[game.id] = game
        }

        simParlayProb = SimulationEngine.shared.simulateParlayProbability(
            picks: picks, logsByName: logsByName, gamesByID: gamesByID
        )
    }

    private func refreshTrackedPicks() async {
        let picks = router.parlayPicks
        let trackedPlayers = router.trackedPlayers
        guard !picks.isEmpty || !trackedPlayers.isEmpty else {
            trackingByPickID = [:]
            trackerRows = []
            return
        }

        let games = dataService.snapshot?.games ?? []
        let details = dataService.gameDetails

        let trackedTeams = Set(trackedPlayers.map { $0.teamAbbrev.uppercased() })
        let relevantGames: [ScheduleGame] = {
            let byTeam = games.filter { trackedTeams.contains($0.awayTeam.uppercased()) || trackedTeams.contains($0.homeTeam.uppercased()) }
            return byTeam.isEmpty ? games : byTeam
        }()

        let gameIDsForTracking = relevantGames.compactMap { $0.gameID }
        let gameIDsForPicks = picks.compactMap { $0.gameID }
        let uniqueGameIDs = Array(Set((gameIDsForTracking + gameIDsForPicks).filter { !$0.isEmpty }))
        var statsByGame: [String: [String: [String: Double]]] = [:]
        for gid in uniqueGameIDs {
            let raw = await dataService.fetchBoxScoreRawForTracking(gameID: gid)
            statsByGame[gid] = extractPlayerStatsByName(fromRawBoxScore: raw)
        }

        var newState: [String: PickTrackingState] = [:]
        for pick in picks {
            let gid = pick.gameID
            let game = gid.flatMap { id in games.first(where: { ($0.gameID ?? "") == id || $0.id == id }) }
            let gameDate = game?.date ?? ""
            let d = gid.flatMap { details[$0] }

            let statusText: String = {
                if let d {
                    if d.statusCode == 3 { return "FINAL" }
                    if d.statusCode == 2 { return d.period > 0 ? "LIVE Q\(d.period)" : "LIVE" }
                }
                return gameDate.isEmpty ? "UPCOMING" : gameDate
            }()

            let scoreText: String? = {
                guard let d else { return nil }
                guard let game else { return nil }
                return "\(game.awayTeam) \(d.awayScore) - \(game.homeTeam) \(d.homeScore)"
            }()

            let statMap = gid.flatMap { statsByGame[$0] }?[pick.playerName.lowercased()]
            let current = currentValue(for: pick.statLabel, from: statMap)

            newState[pick.id] = PickTrackingState(
                statusText: statusText,
                scoreText: scoreText,
                currentValue: current,
                isLive: d?.statusCode == 2,
                isFinal: d?.statusCode == 3
            )
        }

        trackingByPickID = newState

        // Build standalone tracker rows (baseball-app style), even without parlay picks.
        var builtRows: [TrackerRow] = []
        for tracked in trackedPlayers {
            let game = relevantGames.first { g in
                tracked.teamAbbrev.uppercased() == g.awayTeam.uppercased() || tracked.teamAbbrev.uppercased() == g.homeTeam.uppercased()
            }

            guard let game else {
                builtRows.append(TrackerRow(
                    id: tracked.idKey,
                    playerName: tracked.name,
                    teamAbbrev: tracked.teamAbbrev,
                    gameLabel: "No game",
                    statusText: "Off today",
                    currentValue: 0,
                    targetValue: tracked.targetValue,
                    targetLabel: tracked.targetStat.shortLabel,
                    isPositive: false,
                    isFinal: true
                ))
                continue
            }

            let gid = game.gameID ?? ""
            let d = details[gid]
            let statusText: String = {
                if let d {
                    if d.statusCode == 3 { return "FINAL" }
                    if d.statusCode == 2 { return d.period > 0 ? "LIVE Q\(d.period)" : "LIVE" }
                }
                return game.date
            }()

            let statMap = statsByGame[gid]?[tracked.name.lowercased()]
            let current = currentValue(for: tracked.targetStat, from: statMap) ?? 0
            builtRows.append(TrackerRow(
                id: tracked.idKey,
                playerName: tracked.name,
                teamAbbrev: tracked.teamAbbrev,
                gameLabel: "\(game.awayTeam) @ \(game.homeTeam)",
                statusText: statusText,
                currentValue: current,
                targetValue: tracked.targetValue,
                targetLabel: tracked.targetStat.shortLabel,
                isPositive: current > 0,
                isFinal: d?.statusCode == 3
            ))
        }

        trackerRows = builtRows.sorted {
            if $0.isPositive != $1.isPositive { return $0.isPositive && !$1.isPositive }
            return $0.playerName < $1.playerName
        }
    }

    private func extractPlayerStatsByName(fromRawBoxScore raw: String) -> [String: [String: Double]] {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let players = root["players"] as? [[String: Any]]
        else { return [:] }

        var out: [String: [String: Double]] = [:]
        for teamBlock in players {
            guard let groups = teamBlock["statistics"] as? [[String: Any]] else { continue }
            for group in groups {
                let labels = (group["labels"] as? [String]) ?? (group["names"] as? [String]) ?? []
                guard let athletes = group["athletes"] as? [[String: Any]], !labels.isEmpty else { continue }
                for athlete in athletes {
                    guard let athleteObj = athlete["athlete"] as? [String: Any],
                          let displayName = athleteObj["displayName"] as? String,
                          !displayName.isEmpty,
                          let stats = athlete["stats"] as? [Any]
                    else { continue }

                    var mapped = out[displayName.lowercased()] ?? [:]
                    for (idx, label) in labels.enumerated() where idx < stats.count {
                        if let value = toDouble(stats[idx]) {
                            mapped[canonical(label)] = value
                        }
                    }
                    out[displayName.lowercased()] = mapped
                }
            }
        }
        return out
    }

    private func currentValue(for statLabel: String, from map: [String: Double]?) -> Double? {
        guard let map else { return nil }

        let pts = map[canonical("PTS")] ?? map[canonical("points")]
        let reb = map[canonical("REB")] ?? map[canonical("rebounds")]
        let ast = map[canonical("AST")] ?? map[canonical("assists")]
        let threes = map[canonical("3PM")] ?? map[canonical("3pt made")] ?? map[canonical("three point field goals made")]
        let ftm = map[canonical("FTM")] ?? map[canonical("free throws made")]
        let stl = map[canonical("STL")] ?? map[canonical("steals")]
        let blk = map[canonical("BLK")] ?? map[canonical("blocks")]
        let tov = map[canonical("TOV")] ?? map[canonical("turnovers")]

        switch statLabel.uppercased() {
        case "PTS": return pts
        case "REB": return reb
        case "AST": return ast
        case "3PM": return threes
        case "FTM": return ftm
        case "STL": return stl
        case "BLK": return blk
        case "PR":
            guard let p = pts, let r = reb else { return nil }
            return p + r
        case "PA":
            guard let p = pts, let a = ast else { return nil }
            return p + a
        case "RA":
            guard let r = reb, let a = ast else { return nil }
            return r + a
        case "PRA":
            guard let p = pts, let r = reb, let a = ast else { return nil }
            return p + r + a
        case "FPTS":
            guard let p = pts, let r = reb, let a = ast else { return nil }
            return p + (r * 1.2) + (a * 1.5) + ((stl ?? 0) * 3.0) + ((blk ?? 0) * 3.0) - (tov ?? 0)
        default:
            return nil
        }
    }

    private func currentValue(for stat: TrackerStat, from map: [String: Double]?) -> Double? {
        switch stat {
        case .points:
            return currentValue(for: "PTS", from: map)
        case .rebounds:
            return currentValue(for: "REB", from: map)
        case .assists:
            return currentValue(for: "AST", from: map)
        case .threes:
            return currentValue(for: "3PM", from: map)
        case .pra:
            return currentValue(for: "PRA", from: map)
        case .fpts:
            return currentValue(for: "FPTS", from: map)
        case .steals:
            return currentValue(for: "STL", from: map)
        case .blocks:
            return currentValue(for: "BLK", from: map)
        }
    }

    private func canonical(_ raw: String) -> String {
        raw.uppercased().replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
    }

    private func toDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String {
            return Double(s.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                trackerCard

                VStack(spacing: 20) {
                    Image(systemName: "star.slash.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.skyBright.opacity(0.4))

                    Text("No picks yet")
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    Text("Use tracker Add to follow players, or go to Schedule and add props to your parlay.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Button("Go to Schedule") {
                        withAnimation { router.selectedTab = 0 }
                    }
                    .buttonStyle(BrightButtonStyle())
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if !router.parlayPicks.isEmpty {
                Button {
                    takeScreenshot()
                } label: {
                    Image(systemName: isSavingScreenshot ? "hourglass" : "camera")
                        .foregroundColor(.skyBright)
                }
                .disabled(isSavingScreenshot)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if !router.parlayPicks.isEmpty {
                Button("Clear", role: .destructive) {
                    withAnimation { router.clearParlay() }
                }
                .foregroundColor(.red.opacity(0.8))
            }
        }
    }

    // MARK: - Screenshot

    @MainActor
    private func takeScreenshot() {
        isSavingScreenshot = true
        let screenWidth = UIScreen.main.bounds.width
        let renderer = ImageRenderer(content: parlaySnapshotView(width: screenWidth))
        renderer.scale = 3.0
        guard let uiImage = renderer.uiImage else {
            isSavingScreenshot = false
            screenshotMessage = "Failed to render parlay image."
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSavingScreenshot = false
                    screenshotMessage = "Photo access denied. Enable it in Settings → Privacy → Photos."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }) { success, error in
                DispatchQueue.main.async {
                    isSavingScreenshot = false
                    if success {
                        screenshotMessage = "Parlay saved to Photos!"
                    } else {
                        screenshotMessage = error?.localizedDescription ?? "Could not save to Photos."
                    }
                }
            }
        }
    }

    // MARK: - Snapshot view (rendered off-screen at full height by ImageRenderer)

    @ViewBuilder
    private func parlaySnapshotView(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Parlay")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("Shattered Backboard")
                        .font(.caption)
                        .foregroundColor(.skyBright.opacity(0.7))
                }
                Spacer()
                Image(systemName: "basketball.fill")
                    .font(.title2)
                    .foregroundColor(.skyBright)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Summary card
            summaryCard
                .padding(.bottom, 12)

            // All pick rows (no remove button)
            VStack(spacing: 10) {
                ForEach(router.parlayPicks) { pick in
                    ParlayPickRow(pick: pick, tracking: trackingByPickID[pick.id], showRemove: false)
                }
            }
            .padding(.horizontal, 16)

            // Footer
            Text("shatteredbackboard.app")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.25))
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .frame(width: width)
        .background(
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .skyDeep, location: 0.0),
                    .init(color: .skyMid,  location: 0.55),
                    .init(color: .skyDeep, location: 1.0),
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - ParlayPickRow

struct ParlayPickRow: View {
    let pick: PlayerProp
    let tracking: PickTrackingState?
    var showRemove: Bool = true
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        HStack(spacing: 12) {
            // Confidence ring
            confidenceRing

            // Details
            VStack(alignment: .leading, spacing: 3) {
                Text(pick.playerName)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    if let team = pick.team {
                        Text(team)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Text("·")
                        .foregroundColor(.white.opacity(0.3))
                    Text("\(pick.statLabel) \(pick.sideLabel) \(pick.line.cleanLine)")
                        .font(.caption2.bold())
                        .foregroundColor(.white.opacity(0.75))
                }

                HStack(spacing: 6) {
                    if let tracking {
                        Text(tracking.statusText)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(tracking.isFinal ? .white.opacity(0.9) : (tracking.isLive ? .green : .white.opacity(0.65)))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background((tracking.isFinal ? Color.gray : (tracking.isLive ? Color.green : Color.white)).opacity(0.18), in: Capsule())
                    }

                    if let score = tracking?.scoreText, !score.isEmpty {
                        Text(score)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Remove
            if showRemove {
                VStack(alignment: .trailing, spacing: 6) {
                    if let v = tracking?.currentValue {
                        Text("\(v.cleanLine)/\(pick.line.cleanLine)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.skyBright)
                    }
                    Button {
                        withAnimation { router.removeFromParlay(pick) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.skyBorder, lineWidth: 1)
        )
    }

    private var confidenceRing: some View {
        let pct = pick.selectedProbability
        let color: Color = pct >= 0.80 ? .green : pct >= 0.65 ? .skyBright : .orange
        return ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(round(pct * 100)))")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(color)
        }
        .frame(width: 34, height: 34)
    }
}

#Preview {
    QuickPicksView()
}

private struct TrackerTargetSelection {
    let stat: TrackerStat
    let value: Int
}

private struct TrackerPlayerPickerView: View {
    let players: [Player]
    let onAdd: (Player, TrackerTargetSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedStat: TrackerStat = .points
    @State private var targetValue: Double = 20

    private var filteredPlayers: [Player] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return players.prefix(50).map { $0 } }
        return players.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            ($0.team ?? "").localizedCaseInsensitiveContains(q)
        }
        .prefix(80)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Search player", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Picker("Stat", selection: $selectedStat) {
                        ForEach(TrackerStat.allCases, id: \.rawValue) { stat in
                            Text(stat.displayName).tag(stat)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    HStack(spacing: 8) {
                        Text("Line")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper("\(Int(targetValue))", value: $targetValue, in: 1...60, step: 1)
                            .labelsHidden()
                        Text("\(Int(targetValue))")
                            .font(.subheadline.bold())
                            .frame(minWidth: 26, alignment: .trailing)
                    }
                }

                List(filteredPlayers, id: \.playerID) { p in
                    Button {
                        let target = TrackerTargetSelection(stat: selectedStat, value: Int(targetValue))
                        onAdd(p, target)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                    .foregroundColor(.primary)
                                Text((p.team ?? "").uppercased())
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("+ Track")
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("Add Tracker Player")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
