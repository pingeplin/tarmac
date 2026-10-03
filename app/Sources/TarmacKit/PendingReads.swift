/// The requests a scheme handler has started a file read for and not yet
/// answered. A request is known to WebKit by its address, and once it is
/// stopped that address is free for the next request to take; so a read is
/// handed a ticket, and only the ticket of the request still standing at its
/// address gets it answered.
public struct PendingReads<Address: Hashable & Sendable, Request> {
    public struct Ticket: Hashable, Sendable {
        let address: Address
        let turn: UInt64
    }

    private var live: [Address: (turn: UInt64, request: Request)] = [:]
    private var turns: UInt64 = 0

    public init() {}

    public mutating func start(_ address: Address, for request: Request) -> Ticket {
        turns += 1
        live[address] = (turns, request)
        return Ticket(address: address, turn: turns)
    }

    public mutating func stop(_ address: Address) {
        live[address] = nil
    }

    /// The request the read for `ticket` belongs to, taken off the books; nil
    /// when that request was stopped, already answered, or replaced by a later
    /// one at the same address.
    public mutating func finish(_ ticket: Ticket) -> Request? {
        guard let standing = live[ticket.address], standing.turn == ticket.turn else { return nil }
        live[ticket.address] = nil
        return standing.request
    }
}
