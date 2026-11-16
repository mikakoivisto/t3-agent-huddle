import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// A finished row that was settled in T3 while more than a page of other finished threads exist (seen live).
@Suite("Settled behind a full page")
@MainActor
struct SettledBehindAFullPageTests {
    @Test func aSettledRowLeavesEvenWhenTheFinishedListIsPartial() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        s.add(FakeT3Server.FakeThread(id: "thr_mine", title: "Mine", status: "running"))
        let m = makeModel(s)
        m.putAwayCheckInterval = 0
        await m.refresh()
        #expect(m.state.sessions["thr_mine"] != nil)
        s.update("thr_mine") { $0.status = "completed" }
        for i in 0..<30 {   // newer finished threads fill the first page of the finished list
            s.add(FakeT3Server.FakeThread(id: "thr_other_\(i)", title: "Other \(i)", status: "completed"))
        }
        await m.refresh()
        #expect(m.state.sessions["thr_mine"] != nil, "finished, not settled: still shown")
        s.update("thr_mine") { $0.settled = true }
        await m.refresh()
        #expect(m.state.sessions["thr_mine"] == nil, "settled in T3: gone, although the finished list is partial")
    }
}

/// Rows are kept across restarts until the user closes them (spec 02).
@Suite("Kept across restarts")
@MainActor
struct KeptAcrossRestartsTests {
    func finishedLongAgo(_ s: FakeT3Server, _ id: String) {
        s.update(id) { $0.status = "completed" }
        s.mutate { $0[id]?.updatedAt = FakeT3Server.iso(Date().addingTimeInterval(-5 * 3600)) }
    }

    @Test func aDoneRowComesBackAfterARestartUntilClosed() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        s.add(FakeT3Server.FakeThread(id: "thr_done", title: "Done long ago", status: "running"))
        s.add(FakeT3Server.FakeThread(id: "thr_closed", title: "Closed by me", status: "running"))
        let dir = tempDir()
        let first = makeModel(s, prefs: PreferencesStore(directory: dir))
        await first.refresh()
        finishedLongAgo(s, "thr_done"); finishedLongAgo(s, "thr_closed")
        await first.refresh()
        #expect(first.state.sessions["thr_done"]?.attention == .done)
        first.confirmClose("thr_closed")
        await first.refresh()

        // Restart: a 5-hour-old finished thread is not "recently finished", but it was on the list.
        let second = makeModel(s, prefs: PreferencesStore(directory: dir))
        await second.refresh()
        #expect(second.state.sessions["thr_done"] != nil, "kept until closed")
        #expect(second.state.visible.map(\.threadId) == ["thr_done"], "a closed row stays closed")
        let kept = PreferencesStore(directory: dir).load().keptThreads ?? [:]
        #expect(Set(kept.keys) == ["thr_done"])

        // Settled in T3: forgotten, also for the next restart.
        s.update("thr_done") { $0.settled = true }
        await second.refresh()
        #expect(second.state.sessions["thr_done"] == nil)
        #expect((PreferencesStore(directory: dir).load().keptThreads ?? [:]).isEmpty)
        let third = makeModel(s, prefs: PreferencesStore(directory: dir))
        await third.refresh()
        #expect(third.state.sessions.isEmpty)
    }

    @Test func aDeletedThreadIsForgotten() async throws {
        let s = try await startFake(populate: false); defer { s.stop() }
        s.add(FakeT3Server.FakeThread(id: "thr_gone", title: "Gone", status: "running"))
        let dir = tempDir()
        let first = makeModel(s, prefs: PreferencesStore(directory: dir))
        await first.refresh()
        s.mutate { $0["thr_gone"] = nil }
        let second = makeModel(s, prefs: PreferencesStore(directory: dir))
        await second.refresh()
        #expect(second.state.sessions["thr_gone"] == nil)
        #expect((PreferencesStore(directory: dir).load().keptThreads ?? [:]).isEmpty)
    }

    @Test func onlyIdsAreStored() async throws {
        let s = try await startFake(); defer { s.stop() }
        let dir = tempDir()
        let m = makeModel(s, prefs: PreferencesStore(directory: dir))
        await m.refresh()
        let text = try String(contentsOf: dir.appendingPathComponent("preferences.json"), encoding: .utf8)
        for t in m.state.sessions.values.map(\.title) where !t.isEmpty { #expect(!text.contains(t), "no thread titles on disk") }
    }
}
