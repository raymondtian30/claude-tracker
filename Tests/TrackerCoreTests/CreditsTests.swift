import Testing
@testable import TrackerCore

private func aboutCard(_ tab: Tab) -> Card {
    tab.cards.first { $0.title == "About" }!
}

@Test func aboutCardOpensOnAboutWithACreditsSwitch() {
    let card = aboutCard(PanelModel.settingsTab([:], intervalChoices: [15], detected: []))

    #expect(card.items.first == .segmented(label: nil, options: ["About", "Credits"], selected: 0,
                                           action: "about_view"))
    #expect(card.items.contains(.row(label: "Version", value: Version.version)))
    #expect(card.items.contains(.row(label: "Original app by", value: Version.originalAuthor)))
    #expect(card.items.contains { if case .buttons = $0 { return true } else { return false } })
}

@Test func creditsViewListsOriginalCreatorThenContributors() {
    let card = aboutCard(PanelModel.settingsTab([:], intervalChoices: [15], detected: [], showCredits: true))

    #expect(card.items.first == .segmented(label: nil, options: ["About", "Credits"], selected: 1,
                                           action: "about_view"))
    // The original creator keeps their own section, first; then every other
    // GitHub contributor. Names on the left, usernames on the right.
    var expected: [Item] = [.note("Original creator"), .row(label: "Brody Kretz", value: "@BrodyKretz"),
                            .note("Contributors")]
    expected += Credits.contributors.map { .row(label: $0.name ?? $0.login, value: "@\($0.login)") }
    #expect(Array(card.items.dropFirst()) == expected)
    // No version row or update buttons in the credits view.
    #expect(!card.items.contains(.row(label: "Version", value: Version.version)))
    #expect(!card.items.contains { if case .buttons = $0 { return true } else { return false } })
}

@Test func contributorsListSkipsTheOriginalCreator() {
    #expect(!Credits.contributors.contains { $0.login == Credits.originalCreator.login })
    #expect(Credits.contributors.contains { $0.login == "raymondtian30" })
}

@Test func aboutViewActionParses() {
    #expect(AppAction.parse("about_view", .index(1)) == .aboutView(showCredits: true))
    #expect(AppAction.parse("about_view", .index(0)) == .aboutView(showCredits: false))
    #expect(AppAction.parse("about_view", .index(2)) == nil)
}
