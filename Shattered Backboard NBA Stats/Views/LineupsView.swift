//
//  LineupsView.swift — Game picks: full roster for both teams with projections.
//
//  Opened by tapping a game row in HomeView.
//

import SwiftUI

// MARK: - Navigation context

/// Wraps a player + the game they play in so PlayerStatsView gets full context.
struct PlayerGameContext: Hashable {
    let player: Player
    let game: ScheduleGame
}

// MARK: - GamePicksView

struct GamePicksView: View {
    let game: ScheduleGame

    @ObservedObject private var dataService = LocalDataService.shared
    @ObservedObject private var router = AppRouter.shared
    @State private var teamFilter: String = "All"
    @State private var projections: [String: PlayerProjection] = [:]
    @State private var isLoadingProjections = false
    #if DEBUG
    @AppStorage("debugForcePlayoffMode") private var forcePlayoffMode: Bool = false
    #endif

    private let displayStats = ["PTS", "REB", "AST", "PRA"]

    // MARK: Roster

    private func players(for team: String) -> [Player] {
        let starterNames = starters(for: team)
        let outNames     = missingNames(for: team)
        return (dataService.snapshot?.players ?? [])
            .filter { ($0.team ?? "").uppercased() == team.uppercased() }
            .sorted {
                let aOut     = outNames.contains($0.name.lowercased())
                let bOut     = outNames.contains($1.name.lowercased())
                // Injured/out always goes last
                if aOut != bOut { return !aOut }
                // Among active players: confirmed starters first
                let aStarter = starterNames.contains($0.name.lowercased())
                let bStarter = starterNames.contains($1.name.lowercased())
                if aStarter != bStarter { return aStarter }
                // Bench players sorted by projected minutes (descending)
                let mA = projections[$0.playerID]?.minutes ?? -1
                let mB = projections[$1.playerID]?.minutes ?? -1
                if mA != mB { return mA > mB }
                return $0.name < $1.name
            }
    }

    private var awayPlayers: [Player] { players(for: game.awayTeam) }
    private var homePlayers: [Player] { players(for: game.homeTeam) }

    // MARK: Lineup + injury helpers

    private var gameLineup: GameLineup? {
        dataService.snapshot?.lineups.first {
            $0.gameID == game.gameID ||
            ($0.awayTeam?.uppercased() == game.awayTeam.uppercased() &&
             $0.homeTeam?.uppercased() == game.homeTeam.uppercased())
        }
    }

    private func starters(for team: String) -> Set<String> {
        guard let gl = gameLineup else { return [] }
        let list = team.uppercased() == game.awayTeam.uppercased()
            ? gl.awayLineup : gl.homeLineup
        return Set(list.compactMap { $0.name?.lowercased() })
    }

    private func missingPlayers(for team: String) -> [MissingPlayer] {
        team.uppercased() == game.awayTeam.uppercased()
            ? game.missingAwayPlayers
            : game.missingHomePlayers
    }

    private func missingNames(for team: String) -> Set<String> {
        Set(missingPlayers(for: team).compactMap { $0.name?.lowercased() })
    }

    private func injuryInfo(for player: Player, in team: String) -> MissingPlayer? {
        missingPlayers(for: team).first { $0.name?.lowercased() == player.name.lowercased() }
    }

    private func orphanedMissing(for team: String, roster: [Player]) -> [MissingPlayer] {
        let rosterSet = Set(roster.map { $0.name.lowercased() })
        return missingPlayers(for: team).filter {
            ($0.name.map { !rosterSet.contains($0.lowercased()) }) ?? false
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            NightSkyBackground()
            VStack(spacing: 0) {
                matchupHeader
                teamPicker
                playerList
            }
        }
        .navigationTitle("\(game.awayTeam) @ \(game.homeTeam)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PlayerGameContext.self) { ctx in
            PlayerStatsView(player: ctx.player, game: ctx.game)
        }
        .task { await loadProjections() }
        .onChange(of: dataService.snapshotID) { _, _ in Task { await loadProjections() } }
        #if DEBUG
        .onChange(of: forcePlayoffMode) { _, _ in Task { await loadProjections() } }
        #endif
    }

    @MainActor
    private func loadProjections() async {
        guard !isLoadingProjections else { return }
        isLoadingProjections = true
        defer { isLoadingProjections = false }
        let allPlayers = dataService.snapshot?.players ?? []

        // Fetch logs for any game players that have no local data yet
        let gamePlayerIDs = allPlayers
            .filter {
                let t = ($0.team ?? "").uppercased()
                return t == game.awayTeam.uppercased() || t == game.homeTeam.uppercased()
            }
            .map { $0.playerID }
        await dataService.prefetchMissingLogs(playerIDs: gamePlayerIDs)

        projections = PredictionEngine.shared.projectGame(
            game: game,
            players: allPlayers,
            isPlayoffs: isPlayoffForced || game.isPlayoffGame,
            isFirstRound: isPlayoffForced || game.isFirstRound
        )
    }

    private var isPlayoffForced: Bool {
        #if DEBUG
        return forcePlayoffMode
        #else
        return false
        #endif
    }

    // MARK: - Matchup header

    private var matchupHeader: some View {
        HStack {
            VStack(spacing: 2) {
                Text(game.awayTeam).font(.title3.bold()).foregroundColor(.white)
                Text("Away").font(.caption2).foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            VStack(spacing: 2) {
                Text(game.gameTime ?? "TBD")
                    .font(.subheadline.bold()).foregroundColor(.white)
                Text(game.date.shortDate)
                    .font(.caption2).foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            VStack(spacing: 2) {
                Text(game.homeTeam).font(.title3.bold()).foregroundColor(.white)
                Text("Home").font(.caption2).foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.skyMid.opacity(0.5))
    }

    // MARK: - Team picker

    private var teamPicker: some View {
        HStack(spacing: 0) {
            ForEach(["All", game.awayTeam, game.homeTeam], id: \.self) { option in
                Button {
                    teamFilter = option
                    haptic(.light)
                } label: {
                    Text(option)
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(teamFilter == option ? .skyDeep : .white.opacity(0.6))
                        .background(
                            teamFilter == option ? Color.skyBright : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.skyDeep.opacity(0.3))
    }

    // MARK: - Player list

    private var playerList: some View {
        ScrollView {
            if isLoadingProjections && projections.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(.skyBright)
                    Text("Computing projections…")
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 10) {
                    if teamFilter != game.homeTeam {
                        teamSection(game.awayTeam, players: awayPlayers, label: "Away")
                    }
                    if teamFilter != game.awayTeam {
                        teamSection(game.homeTeam, players: homePlayers, label: "Home")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private func teamSection(_ team: String, players: [Player], label: String) -> some View {
        let starterSet = starters(for: team)
        let orphans    = orphanedMissing(for: team, roster: players)

        HStack {
            Text(team).font(.caption.bold()).foregroundColor(.skyBright)
            Text("· \(label)").font(.caption).foregroundColor(.white.opacity(0.35))
            Spacer()
            Text("\(players.count + orphans.count) players")
                .font(.caption2).foregroundColor(.white.opacity(0.25))
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)

        ForEach(players) { player in
            PlayerPickCard(
                player: player,
                game: game,
                projection: projections[player.playerID],
                displayStats: displayStats,
                isStarter: starterSet.contains(player.name.lowercased()),
                injuryStatus: injuryInfo(for: player, in: team)
            )
        }

        ForEach(orphans, id: \.self) { mp in
            MissingPlayerRow(missingPlayer: mp)
        }
    }
}

// MARK: - PlayerPickCard

struct PlayerPickCard: View {
    let player: Player
    let game: ScheduleGame
    let projection: PlayerProjection?
    let displayStats: [String]
    let isStarter: Bool
    let injuryStatus: MissingPlayer?

    private func injuryColor(_ status: String?) -> Color {
        switch (status ?? "").uppercased() {
        case "OUT":      return .red.opacity(0.85)
        case "DOUBTFUL": return .orange
        default:         return .yellow.opacity(0.85)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Player header — name is tappable → PlayerStatsView
            HStack {
                NavigationLink(value: PlayerGameContext(player: player, game: game)) {
                    Text(player.name)
                        .font(.subheadline.bold())
                        .foregroundColor(.skyBright)
                }
                .buttonStyle(.plain)
                if let pos = player.position, !pos.isEmpty {
                    Text(pos)
                        .font(.caption2.bold())
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                if isStarter {
                    Label("STARTING", systemImage: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.black.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green, in: Capsule())
                }
                Spacer()
                if let inj = injuryStatus {
                    Text(inj.status ?? "OUT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(injuryColor(inj.status), in: Capsule())
                } else {
                    Text(player.team ?? "")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(Color.skyBorder)

            if let inj = injuryStatus, let reason = inj.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundColor(.orange.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                Divider().background(Color.skyBorder)
            }

            VStack(spacing: 0) {
                ForEach(displayStats, id: \.self) { stat in
                    PickStatRow(stat: stat, player: player,
                                gameID: game.gameID, projection: projection)
                    if stat != displayStats.last {
                        Divider()
                            .background(Color.white.opacity(0.05))
                            .padding(.leading, 14)
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .background(Color.skyCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(injuryStatus != nil ? Color.red.opacity(0.35) : Color.skyBorder, lineWidth: 1)
        )
        .opacity(injuryStatus != nil ? 0.75 : 1.0)
    }
}

// MARK: - MissingPlayerRow

struct MissingPlayerRow: View {
    let missingPlayer: MissingPlayer

    private func injuryColor(_ status: String?) -> Color {
        switch (status ?? "").uppercased() {
        case "OUT":      return .red.opacity(0.85)
        case "DOUBTFUL": return .orange
        default:         return .yellow.opacity(0.85)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(missingPlayer.name ?? "Unknown Player")
                    .font(.subheadline.bold())
                    .foregroundColor(.white.opacity(0.45))
                if let reason = missingPlayer.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.7))
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(missingPlayer.status ?? "OUT")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(injuryColor(missingPlayer.status), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.skyCard.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
        .opacity(0.65)
    }
}

// MARK: - PickStatRow

struct PickStatRow: View {
    let stat: String
    let player: Player
    let gameID: String?
    let projection: PlayerProjection?

    @ObservedObject private var router = AppRouter.shared
    @State private var showBlocked = false

    private var engineLine: Double { projection?.line(for: stat)  ?? 0 }
    private var engineProj: Double { projection?.value(for: stat) ?? 0 }
    private var engineConf: Double { projection?.confidence(for: stat) ?? 0 }
    private var hasData:    Bool   { (projection?.gameCount ?? 0) > 0 }

    private var engineProp: PlayerProp {
        PlayerProp(
            id: "\(gameID ?? "")_\(player.name)_\(stat)",
            gameID: gameID,
            playerName: player.name,
            team: player.team,
            statLabel: stat,
            line: max(0.5, engineLine),
            overPct: hasData ? engineConf : nil,
            projectedValue: engineProj > 0 ? engineProj : nil
        )
    }

    private var inParlay: Bool { router.isInParlay(engineProp) }
    private var canAdd:   Bool { router.canAdd(engineProp) }

    var body: some View {
        HStack(spacing: 10) {
            // Stat chip
            Text(stat)
                .font(.caption2.bold())
                .foregroundColor(.black.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(nbaStatColor(stat), in: Capsule())
                .frame(width: 42)

            // Line + projection
            VStack(alignment: .leading, spacing: 1) {
                if hasData && engineLine > 0 {
                    Text("OVER \(engineLine.cleanLine)")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.85))
                    Text("proj \(engineProj.cleanLine)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.skyBright.opacity(0.65))
                } else {
                    Text("No recent data")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            Spacer()

            // Confidence
            if hasData {
                let color: Color = engineConf >= 0.80 ? .green : engineConf >= 0.65 ? .skyBright : .orange
                Text("\(Int(round(engineConf * 100)))%")
                    .font(.caption.bold())
                    .foregroundColor(color)
                    .frame(width: 38, alignment: .trailing)
            }

            // Add / remove button
            if inParlay {
                Button {
                    router.removeFromParlay(engineProp)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.skyBright)
                }
            } else {
                Button {
                    if !router.addToParlay(engineProp) { showBlocked = true }
                } label: {
                    Image(systemName: canAdd ? "plus.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundColor(canAdd ? .skyBright : .white.opacity(0.25))
                }
                .disabled(!canAdd || !hasData)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(inParlay ? Color.skyBright.opacity(0.08) : Color.clear)
        .alert("Can't add to Picks", isPresented: $showBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.blockedReason(for: engineProp) ?? "")
        }
    }
}
