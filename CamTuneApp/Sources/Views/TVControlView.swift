import SwiftUI

struct TVControlView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Playback controls
            VStack(spacing: 8) {
                Text("Playback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 16) {
                    Button {
                        Task { await state.tvPlayPause() }
                    } label: {
                        Image(systemName: "playpause.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        Task { await state.tvNext() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Divider()

            // Concert Series
            Button {
                Task { await state.startConcert() }
            } label: {
                Label("Start Concert Series", systemImage: "music.note.tv")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Divider()

            // Audio routing
            VStack(spacing: 8) {
                Text("Audio Output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("", selection: $state.audioRoute) {
                    ForEach(AudioRoute.allCases, id: \.self) { route in
                        Text(route.label).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.audioRoute) { _, newRoute in
                    Task { await state.setAudioRoute(newRoute) }
                }
            }

            Divider()

            // Power
            HStack(spacing: 12) {
                Button {
                    Task { await state.tvWake() }
                } label: {
                    Label("Wake", systemImage: "power")
                }
                .controlSize(.small)

                Button {
                    Task { await state.tvSleep() }
                } label: {
                    Label("Sleep", systemImage: "moon.fill")
                }
                .controlSize(.small)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
