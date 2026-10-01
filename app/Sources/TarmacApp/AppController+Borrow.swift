import AppKit
import TarmacKit

extension AppController {
    /// Hooks an HTML card's borrow gesture and its document's Escape.
    func wireBorrow(_ card: CardView) {
        guard let html = card.htmlBody else { return }
        let id = card.id
        html.onBorrow = { [weak self] in self?.borrowCard(id) }
        html.onEscapeHome = { [weak self] in self?.escapeHome() }
    }

    /// A double-click on an HTML card's shield: the shield comes off and the
    /// document takes the keyboard.
    func borrowCard(_ id: CardID) {
        borrow.borrow(id)
        applyBorrow()
        activeBoard.view.card(id)?.htmlBody?.focusDocument()
    }

    /// Un-borrows the HTML card and puts the keyboard back on the prime
    /// terminal, so one Escape goes home.
    func escapeHome() {
        _ = borrow.release()
        applyBorrow()
        focusPrimeTerminal()
    }

    /// Draws every HTML card as the borrow has it. A board switch leaves the
    /// borrow where it is, and the card on the board that left the screen is
    /// drawn shielded until that board comes back.
    func applyBorrow() {
        for board in boards.values {
            let visible = board === activeBoard
            for card in board.view.cards.values {
                guard let html = card.htmlBody else { continue }
                let borrowed = borrow.shows(card.id, boardVisible: visible)
                card.setBorrowed(borrowed)
                html.setBorrowed(borrowed)
            }
        }
    }
}
