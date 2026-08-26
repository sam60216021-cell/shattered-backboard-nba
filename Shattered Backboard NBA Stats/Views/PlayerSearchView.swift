//
//  PlayerSearchView.swift — Global player search tab.
//
//  Shows all players from the local roster; as you type the list filters live.
//  Tap any row to open that player's full PlayerStatsView.
//

import SwiftUI

struct PlayerSearchView: View {

    @ObservedObject private var dataService = LocalDataService.shared
    @State private var searchText = ""
    @State private var selectedPlayer: Player? = nil

    // MARK: - Derived

    private var allPlayers: [Player] {
        (dataService.snapshot?.players ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredPlayers: [Player] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return allPlayers }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return allPlayers.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                NightSkyBackground()
                content
            }
            .navigationTitle("Players")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search players…"
            )
            .autocorrectionDisabled()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if allPlayers.isEmpty {
            emptyRoster
        } else if filteredPlayers.isEmpty {
            noResults
        } else {
            playerList
        }
    }

    private var playerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredPlayers) { player in
                    NavigationLink(destination: PlayerStatsView(player: player, game: nil)) {
                        PlayerSearchRow(player: player)
                    }
                    .buttonStyle(.plain)
                    Divider()
                        .background(Color.skyBorder)
                        .padding(.leading, 56)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private var emptyRoster: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(.skyBright.opacity(0.4))
            Text("No players yet")
                .font(.title3.bold())
                .foregroundColor(.white)
            Text("Player data loads automatically in the background.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.skyBright.opacity(0.35))
            Text("No players match \"\(searchText)\"")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - PlayerSearchRow

private struct PlayerSearchRow: View {
    let player: Player

    var body: some View {
        HStack(spacing: 12) {
            // Avatar circle with initials
            ZStack {
                Circle()
                    .fill(Color.skyAccent.opacity(0.35))
                    .frame(width: 36, height: 36)
                Text(initials)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.skyBright)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(player.name)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                HStack(spacing: 6) {
                    if let team = player.team {
                        Text(team)
                            .font(.caption2.bold())
                            .foregroundColor(.skyBright.opacity(0.75))
                    }
                    if let pos = player.position, !pos.isEmpty {
                        Text("·")
                            .foregroundColor(.white.opacity(0.3))
                        Text(pos)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.2))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var initials: String {
        let parts = player.name.split(separator: " ")
        switch parts.count {
        case 0: return "?"
        case 1: return String(parts[0].prefix(2)).uppercased()
        default:
            let first = parts.first.map { String($0.prefix(1)) } ?? ""
            let last  = parts.last.map  { String($0.prefix(1)) } ?? ""
            return (first + last).uppercased()
        }
    }
}

#Preview {
    PlayerSearchView()
}
