import Testing
import Foundation
@testable import HuddleCore
import FakeT3

/// Attention indicator and settings (spec 14): the count, the header pill's jump, bringing a hidden panel back, the settings.
@Suite("Attention indicator (spec 14)")
@MainActor
struct AttentionTests {
    // ATT-01, ATT-03
    @Test func theCountIsQuestionsPermissionsAndSecretsThatAreShown() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        #expect(Set(m.attentionSessions.map(\.threadId)) == [Scenario.questionThread, Scenario.permissionThread])
        #expect(m.menuBarTooltip.hasPrefix("2 need you"))
        m.closeTapped(Scenario.questionThread); m.closeTapped(Scenario.questionThread)
        #expect(m.attentionSessions.map(\.threadId) == [Scenario.permissionThread], "a closed thread does not count")
    }

    @Test func theTooltipSaysBothNumbers() {
        #expect(HuddleModel.tooltip(attention: 2, working: 3) == "2 need you · 3 running")
        #expect(HuddleModel.tooltip(attention: 1, working: 0) == "1 needs you")
        #expect(HuddleModel.tooltip(attention: 0, working: 4) == "4 running")
        #expect(HuddleModel.tooltip(attention: 0, working: 0) == "Agent Huddle")
    }

    // ATT-02
    @Test func thePillOpensTheListAndGoesToTheFirstThreadThatNeedsYou() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        m.openDetail(Scenario.renderThread)
        m.toggleCollapsed()
        m.revealAttention(excluding: Scenario.renderThread)
        #expect(!m.collapsed && m.selectedThreadID == nil)
        let first = try #require(m.attentionSessions.first?.threadId)
        #expect(m.revealThreadId == first && m.flashThreadId == first)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        #expect(m.flashThreadId == nil, "the outline flashes once")
    }

    @Test func inAThreadThatNeedsYouThePillPointsToAnotherOne() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        m.openDetail(Scenario.questionThread)
        m.revealAttention(excluding: Scenario.questionThread)
        #expect(m.revealThreadId == Scenario.permissionThread)
    }

    // ATT-04
    @Test func aHiddenPanelComesBackForANewRequestOnlyWhenTurnedOn() async throws {
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s)
        await m.refresh()
        m.hideWidget()
        s.add(.init(id: "thr_new_q", title: "New question", status: "waiting", questions: [
            .init(requestId: "rq_new", header: "PICK", question: "Which?", options: ["A", "B"])]))
        await m.refresh()
        #expect(m.widgetHidden, "off by default: the panel stays hidden")

        m.setShowPanelOnAttention(true)
        s.add(.init(id: "thr_new_p", title: "Another question", status: "waiting", questions: [
            .init(requestId: "rq_new2", header: "PICK", question: "Which?", options: ["A", "B"])]))
        await m.refresh()
        #expect(!m.widgetHidden, "a new request brings it back")
        m.hideWidget()
        await m.refresh()
        #expect(m.widgetHidden, "the same requests do not bring it back again")
    }

    @Test func settingsPersistAndAnOlderPreferencesFileStillLoads() async throws {
        let dir = tempDir()
        try Data(#"{"hiddenIDs":[],"collapsed":false,"muted":false,"readOnly":false,"closeSettles":false}"#.utf8)
            .write(to: dir.appendingPathComponent("preferences.json"))
        let s = try await startFake(); defer { s.stop() }
        let m = makeModel(s, prefs: PreferencesStore(directory: dir))
        #expect(!m.showPanelOnAttention && m.settingsOnTop, "defaults: bring-back off, settings on top")
        m.setShowPanelOnAttention(true); m.setSettingsOnTop(false); m.setChime(false)
        let again = makeModel(s, prefs: PreferencesStore(directory: dir))
        #expect(again.showPanelOnAttention && !again.settingsOnTop && again.muted)
        again.setChime(true)
        #expect(!again.muted, "Chime and the speaker button are one setting")
    }
}
