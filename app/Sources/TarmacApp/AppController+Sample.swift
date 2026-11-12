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
    /// largest pending count is taken, and so reset, here.
    func gatherSample() -> SampleGathered {
        var gathered = SampleGathered(daemonPid: daemonSession.daemonPid)
        gathered.boardsCount = boardMetas.count
        gathered.boardsLoaded = boards.count
        for board in boards.values {
            for card in board.view.cards.values {
                guard case .doc(let path) = card.id else {
                    gathered.cardsTerminal += 1
                    continue
                }
                if let html = card.htmlBody {
                    gathered.cardsHTML += 1
                    gathered.pending.append(SampleLine.Pending(path: path, count: html.takeLargestPending()))
                } else {
                    gathered.cardsMarkdown += 1
                }
                if let pid = card.docBody?.webProcessID {
                    gathered.webViews.append(SampleGathered.WebView(pid: pid, path: path))
                }
            }
        }
        return gathered
    }
}
