import Darwin
import Foundation
import dnssd

/// This fork: publishes `tether.local` with mDNS (Bonjour) as the IPv6 address Tether listens on, on
/// the hotspot's bridge only. On a carrier that gives the iPhone IPv6 only, that address comes with
/// each cellular session, so a config with the address stops working when it changes. A config with
/// the name keeps working: the name follows the address. See `HotspotSession.deviceHost`.
///
/// Only an AAAA record: on such a hotspot the devices can't reach 172.20.10.1, and a name with IPv4
/// too would have them try that first.
@MainActor
final class HostNamePublisher {
    static let name = "tether.local"

    private let log: @MainActor (String) -> Void
    private var connection: DNSServiceRef?
    private var published: (address: String, interface: String)?
    private var lastFailure: String?

    init(log: @escaping @MainActor (String) -> Void) {
        self.log = log
    }

    /// Points the name at `address` on its interface, or takes it down with nil. Called every watcher
    /// round, so it does nothing while that stays the same.
    func publish(_ address: String?) {
        guard let address, let interface = Self.interface(of: address) else {
            if published != nil {
                withdraw()
                log("mDNS: \(Self.name) withdrawn")
            }
            return
        }
        if let published, published.address == address, published.interface == interface { return }
        withdraw()

        var bytes = in6_addr()
        guard inet_pton(AF_INET6, address, &bytes) == 1 else { return }
        var ref: DNSServiceRef?
        var error = DNSServiceCreateConnection(&ref)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            fail("couldn't connect to mDNS (\(error))")
            return
        }
        error = DNSServiceSetDispatchQueue(ref, .main)
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            DNSServiceRefDeallocate(ref)
            fail("couldn't set up mDNS (\(error))")
            return
        }
        var record: DNSRecordRef?
        error = withUnsafeBytes(of: &bytes) { raw in
            DNSServiceRegisterRecord(
                ref, &record,
                DNSServiceFlags(kDNSServiceFlagsUnique),
                if_nametoindex(interface),
                Self.name + ".",
                UInt16(kDNSServiceType_AAAA),
                UInt16(kDNSServiceClass_IN),
                UInt16(raw.count),
                raw.baseAddress,
                120,
                HostNamePublisher.reply,
                nil)
        }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            DNSServiceRefDeallocate(ref)
            fail("couldn't publish \(Self.name) (\(error))")
            return
        }
        connection = ref
        published = (address, interface)
        lastFailure = nil
        log("mDNS: \(Self.name) is \(address) on \(interface)")
    }

    private func withdraw() {
        if let connection { DNSServiceRefDeallocate(connection) } // takes its records with it
        connection = nil
        published = nil
    }

    private func fail(_ failure: String) {
        if failure != lastFailure { log("mDNS: \(failure)") }
        lastFailure = failure
    }

    /// A name conflict or a lost registration shows in Console; the next address change publishes again.
    private static let reply: DNSServiceRegisterRecordReply = { _, _, _, error, _ in
        if error != DNSServiceErrorType(kDNSServiceErr_NoError) {
            NSLog("Tether mDNS: %@ registration error %d", HostNamePublisher.name, error)
        }
    }

    /// The interface that has `address`, the hotspot's bridge.
    private static func interface(of address: String) -> String? {
        Interfaces.addresses().lazy
            .map { $0.components(separatedBy: ": ") }
            .first { $0.count == 2 && $0[1] == address }?
            .first
    }
}
