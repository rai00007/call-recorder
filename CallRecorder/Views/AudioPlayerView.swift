import SwiftUI

struct AudioPlayerView: View {
    @StateObject private var player: PlayerModel
    @State private var scrubbing = false
    @State private var position = 0.0

    init(url: URL) { _player = StateObject(wrappedValue: PlayerModel(url: url)) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Text(formatDuration(scrubbing ? position : player.currentTime)).monospacedDigit()
                Slider(value: Binding(get: { scrubbing ? position : player.currentTime },
                                      set: { position = $0 }),
                       in: 0...max(player.duration, 1)) { scrubbing = $0; if !$0 { player.seek(to: position) } }
                Text(formatDuration(player.duration)).monospacedDigit()
            }
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 360)
        }
        .onDisappear { player.pause() }
    }
}
