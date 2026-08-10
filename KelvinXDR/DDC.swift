//
//  DDC.swift
//  KelvinXDR
//
//  VESA DDC/CI (MCCS) brightness control for external displays, over I2C.
//
//  This talks to the monitor's own firmware — the same setting its physical buttons change —
//  so it is real hardware brightness, not a software dim. Unrelated to the gamma path in
//  GammaBoost, which only applies to the built-in panel.
//
//  Ported from MonitorControl's Arm64DDC.swift (MIT) — github.com/MonitorControl/MonitorControl
//

import Foundation
import IOKit

enum DDC {
    // MCCS VCP codes. Both LG panels here report support for all of these.
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
    static let volume: UInt8 = 0x62
    /// 1 = muted, 2 = unmuted.
    static let mute: UInt8 = 0x8D

    private static let sevenBitAddress: UInt8 = 0x37
    private static let dataAddress: UInt8 = 0x51

    // MARK: - Discovery

    /// EDID serial number -> I2C service, for every externally connected display.
    ///
    /// ponytail: matched on serial alone, which is exact on this hardware. MonitorControl
    /// runs a 20-point fuzzy match over vendor/product/manufacture-date/image-size because
    /// serials can be zero or collide on cheap panels. Upgrade to that if a display ever
    /// binds to the wrong slider.
    static func services() -> [Int64: IOAVService] {
        var found: [Int64: IOAVService] = [:]
        var current: (serial: Int64, product: String) = (0, "")

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, "IOService",
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return found }
        defer { IOObjectRelease(iterator) }

        // The registry lists a framebuffer node, then the AV service proxy that belongs to it.
        let framebuffers = ["AppleCLCD2", "IOMobileFramebufferShim"]

        while let (name, entry) = nextEntry(matching: ["DCPAVServiceProxy"] + framebuffers, iterator: &iterator) {
            // One release covering every path out of the loop body, `continue` included.
            // IOAVServiceCreateWithService takes its own reference, so handing the entry back
            // here does not invalidate the service we keep.
            defer { IOObjectRelease(entry) }

            if framebuffers.contains(name) {
                current = (0, "")
                if let attrs = property(entry, "DisplayAttributes") as? NSDictionary,
                   let product = attrs.value(forKey: "ProductAttributes") as? NSDictionary {
                    current.serial = product.value(forKey: "SerialNumber") as? Int64 ?? 0
                    current.product = product.value(forKey: "ProductName") as? String ?? ""
                }
            } else if name == "DCPAVServiceProxy" {
                // "Embedded" is the built-in panel — it has no I2C channel.
                guard let location = property(entry, "Location") as? String, location == "External",
                      current.serial != 0,
                      let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?
                          .takeRetainedValue() as IOAVService? else { continue }
                found[current.serial] = service
            }
        }
        return found
    }

    private static func property(_ entry: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively))?.takeRetainedValue()
    }

    private static func nextEntry(matching interests: [String],
                                  iterator: inout io_iterator_t) -> (String, io_service_t)? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { buffer.deallocate() }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != MACH_PORT_NULL else { return nil }
            guard IORegistryEntryGetName(entry, buffer) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                return nil
            }
            let name = String(cString: buffer)
            // IOIteratorNext hands back a retained object every time. The caller releases the
            // ones we return; anything we skip has to be released here or the port table grows
            // on every call, and this runs again on every hotplug.
            if interests.contains(where: { name.contains($0) }) { return (name, entry) }
            IOObjectRelease(entry)
        }
    }

    // MARK: - I2C

    static func read(_ service: IOAVService, _ command: UInt8) -> (current: UInt16, max: UInt16)? {
        var send: [UInt8] = [command]
        var reply = [UInt8](repeating: 0, count: 11)
        guard communicate(service, send: &send, reply: &reply, expecting: command) else { return nil }
        return parseReply(reply, command: command)
    }

    /// Validate and unpack a Get-VCP-Feature reply. Internal so the hardware-free tests can
    /// exercise it with synthetic replies.
    ///
    /// A checksum-valid reply can still be the wrong one: a non-zero result code (byte 3)
    /// means "unsupported VCP" and arrives zero-filled — parsed blindly, that put a volume
    /// row on speakerless monitors and quantised brightness to a max of 1. The opcode echo
    /// (byte 4) catches a reply consumed off the bus for a *different* request. And max == 0
    /// is never a usable scale, whatever the monitor meant by it.
    static func parseReply(_ reply: [UInt8], command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count == 11, reply[3] == 0, reply[4] == command else { return nil }
        let maxValue = UInt16(reply[6]) * 256 + UInt16(reply[7])
        guard maxValue > 0 else { return nil }
        return (UInt16(reply[8]) * 256 + UInt16(reply[9]), maxValue)
    }

    /// - retries: 0 during a smooth transition — an intermediate frame that misses is
    ///   immediately superseded, and retrying would make the ramp lag behind the keypress.
    @discardableResult
    static func write(_ service: IOAVService, _ command: UInt8, _ value: UInt16, retries: Int = 4) -> Bool {
        var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 255)]
        var reply: [UInt8] = []
        return communicate(service, send: &send, reply: &reply, retries: retries)
    }

    /// Coalescing, per-display writer.
    ///
    /// An I2C exchange costs 20-40ms, but a continuous slider fires dozens of events per
    /// drag. Queueing them all means the monitor is still working through stale values
    /// seconds after you let go, and a queue shared between displays makes the second
    /// monitor visibly trail the first. So: at most one write in flight per
    /// (display, command), newer values replace older ones instead of queueing behind them,
    /// and different displays never wait on each other.
    final class Writer {
        private struct Key: Hashable {
            let display: CGDirectDisplayID
            let command: UInt8
        }

        private let lock = DispatchQueue(label: "KelvinXDR.ddc.coalesce")
        private var pending: [Key: (service: IOAVService, value: UInt16)] = [:]
        private var inFlight: Set<Key> = []

        func write(_ service: IOAVService, display: CGDirectDisplayID, command: UInt8, value: UInt16) {
            let key = Key(display: display, command: command)
            lock.async {
                self.pending[key] = (service, value)
                guard !self.inFlight.contains(key) else { return }
                self.inFlight.insert(key)
                self.drain(key)
            }
        }

        private func drain(_ key: Key) {
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    var next: (service: IOAVService, value: UInt16)?
                    var more = false
                    self.lock.sync {
                        next = self.pending.removeValue(forKey: key)
                        if next == nil { self.inFlight.remove(key) }
                    }
                    guard let job = next else { return }
                    self.lock.sync { more = self.pending[key] != nil }
                    // Don't burn retries on a value that is already superseded.
                    DDC.write(job.service, key.command, job.value, retries: more ? 0 : 3)
                }
            }
        }
    }

    static let writer = Writer()

    /// One lock per I2C service: a DDC exchange is a stateful write-sleep-read on a single
    /// bus address, and the refresh scan's reads run on a different thread from the Writer's
    /// drains. Interleaving two exchanges crosses their replies — the opcode check in
    /// `parseReply` *detects* that; this prevents it. Per service rather than one global
    /// lock so different displays still never wait on each other (the Writer's whole design).
    ///
    /// Entries are never pruned: a handful of NSLocks per hotplug is noise, and a reused
    /// object identity at worst shares a lock, which only over-serialises.
    private static let busLocksLock = NSLock()
    private static var busLocks: [ObjectIdentifier: NSLock] = [:]

    private static func busLock(for service: IOAVService) -> NSLock {
        busLocksLock.lock()
        defer { busLocksLock.unlock() }
        let key = ObjectIdentifier(service as AnyObject)
        if let lock = busLocks[key] { return lock }
        let lock = NSLock()
        busLocks[key] = lock
        return lock
    }

    /// - expecting: for reads, the VCP opcode the reply must echo. The monitor holds ONE
    ///   reply buffer and overwrites it when it gets around to a request, so a checksum-valid
    ///   reply echoing a previous opcode means "not ready yet", not "failed" — the right move
    ///   is to read again *without* re-sending. Re-sending is the classic mistake: it queues
    ///   another answer and the conversation stays one reply behind for the rest of the
    ///   session, which is exactly how a panel "loses" its volume row until the next hotplug.
    ///   Measured on both LGs: the first request after bus idle can take >50ms to answer.
    private static func communicate(_ service: IOAVService, send: inout [UInt8], reply: inout [UInt8],
                                    retries: Int = 4, expecting: UInt8? = nil) -> Bool {
        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        packet[packet.count - 1] = checksum(
            send.count == 1 ? sevenBitAddress << 1 : sevenBitAddress << 1 ^ dataAddress,
            &packet, 0, packet.count - 2)

        let lock = busLock(for: service)
        lock.lock()
        defer { lock.unlock() }

        var success = false
        for _ in 0...max(retries, 0) {
            for _ in 1...2 {
                usleep(10000)
                success = IOAVServiceWriteI2C(service, UInt32(sevenBitAddress), UInt32(dataAddress),
                                              &packet, UInt32(packet.count)) == 0
            }
            if !reply.isEmpty {
                success = false
                for _ in 0..<4 {
                    usleep(50000)
                    guard IOAVServiceReadI2C(service, UInt32(sevenBitAddress), 0, &reply, UInt32(reply.count)) == 0,
                          checksum(0x50, &reply, 0, reply.count - 2) == reply[reply.count - 1]
                    else { continue }
                    // A stale echo: our request has not been processed yet. Keep reading.
                    if let expecting = expecting, reply.count > 4, reply[4] != expecting { continue }
                    success = true
                    break
                }
            }
            if success { return true }
            usleep(20000)
        }
        return success
    }

    private static func checksum(_ seed: UInt8, _ data: inout [UInt8], _ start: Int, _ end: Int) -> UInt8 {
        var result = seed
        for i in start...end { result ^= data[i] }
        return result
    }
}
