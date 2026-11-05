import SwiftUI
import UIKit

/// This fork: shows where a device's traffic stops. Refreshes every second.
///
/// - Packets in stays 0: the device sends nothing into the tunnel (its VPN app routes elsewhere).
/// - Dropped for source address grows: the device sends from an address that isn't its own.
/// - TCP failed grows: the iPhone can't make the connection out, see Last error.
struct DiagnosticsView: View {
    let model: Model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let d = model.diagnostics
            List {
                Section {
                    copyRow("Listening on", d.listening ?? "Not running")
                    if let listening = d.listening, listening.contains(":") {
                        copyRow("Endpoint", "[\(listening)]:51820")
                    }
                } header: { Text("This iPhone") } footer: {
                    Text("Tap a row to copy it.")
                }

                ForEach(model.wireGuardPeers) { peer in
                    let p = d.snapshot.peers[peer.address]
                    Section(peer.name) {
                        LabeledContent("Tunnel address", value: peer.address)
                        LabeledContent("Last handshake", value: ago(p?.lastHandshake, now: context.date))
                        LabeledContent("From", value: p?.endpoint ?? "—")
                        LabeledContent("Up / down", value: "\(bytes(p?.traffic.bytesUp)) / \(bytes(p?.traffic.bytesDown))")
                    }
                }

                if let g = d.snapshot.diag {
                    Section {
                        LabeledContent("Packets in", value: "\(g.received)")
                        copyRow("Last packet in", g.lastIn.isEmpty ? "—" : g.lastIn)
                        LabeledContent("Dropped for source address", value: "\(g.disallowed)")
                        LabeledContent("TCP opened / failed", value: "\(g.tcpTried) / \(g.tcpFailed)")
                        LabeledContent("UDP send failed", value: "\(g.udpFailed)")
                        LabeledContent("NAT64 prefix", value: g.nat64.isEmpty ? "—" : g.nat64)
                        copyRow("Last error", g.lastError.isEmpty ? "—" : g.lastError)
                    } header: { Text("Server") } footer: {
                        Text("Since the hotspot came on. Packets in stays 0 when the device sends nothing into the tunnel.")
                    }
                }
            }
            .font(.callout)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copyRow(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.secondary).font(.caption)
                Text(value).foregroundStyle(.primary).textSelection(.enabled)
            }
        }
    }

    private func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let s = Int(now.timeIntervalSince(date))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min \(s % 60) s ago"
    }

    private func bytes(_ n: UInt64?) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n ?? 0), countStyle: .binary)
    }
}
