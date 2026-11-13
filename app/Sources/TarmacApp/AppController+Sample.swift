import Foundation
import TarmacKit

extension AppController {
    // MARK: - Sample log

    func startSampling() {
        sampleLog.start(intervalSeconds: Self.sampleIntervalSeconds)
    }

    /// The seam for the live check is compiled out of a release build.
    private static var sampleIntervalSeconds: TimeInterval {
        #if DEBUG
        SampleInterval.seconds(override: ProcessInfo.processInfo.environment["TARMAC_SAMPLE_INTERVAL_S"])
        #else
        SampleInterval.defaultSeconds
        #endif
    }

    /// The counts are over the boards this app has built; each HTML card's
    /// pending peak is taken, and so reset, here: that take is also what lets
    /// the card give its next over-limit line. The footprints are
    /// left unread: `SampleLog` reads them off the main actor.
    func gatherSample() -> SampleLine.Sample {
        var sample = SampleLine.Sample(
            appFootprint: nil, daemonPid: daemonSession.daemonPid, daemonFootprint: nil,
            boardsCount: boardMetas.count, boardsLoaded: boards.count,
            cardsHTML: 0, cardsMarkdown: 0, cardsTerminal: 0, pending: [], webContent: []
        )
        for board in boards.values {
            for card in board.view.cards.values {
                guard case .doc(let path) = card.id else {
                    sample.cardsTerminal += 1
                    continue
                }
                if let html = card.htmlBody {
                    sample.cardsHTML += 1
                    let peak = html.takePendingPeak()
                    sample.pending.append(SampleLine.Pending(path: path, largest: peak.largest, timesOver: peak.timesOver))
                } else {
                    sample.cardsMarkdown += 1
                }
                if let pid = card.docBody?.webProcessID {
                    sample.webContent.append(SampleLine.WebContent(pid: pid, path: path, footprint: nil))
                }
            }
        }
        return sample
    }
}
