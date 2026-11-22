import Foundation
@testable import LampBibleMacSupport
import LampCore
import Testing

/// How a phone's choice of provider, model and effort is taken into a chat,
/// as the menus over a window's chat take one.
struct LampAgentRemoteChoicesHostingTests {
    private func wire(_ id: String) -> AgentChatWireProvider? {
        id == "openCode" ? .openCode : AgentChatWireProvider(rawValue: id)
    }

    private let remembered: [String: String] = [
        "chat.model.claude": "sonnet",
        "chat.effort.claude": "high",
        "chat.model.openCode": "anthropic/claude#max",
    ]

    private func apply(_ change: LampAgentRemoteChoices, to choices: AgentChatChoices = .init()) throws -> (choices: AgentChatChoices, remembered: [String: String]) {
        try LampAgentRemoteHosting.applying(
            change, to: choices, appProviderID: "codex", appProviderKey: "reader.chat.provider",
            wire: wire, appDefault: { remembered[$0] }
        )
    }

    @Test func aProviderPickedOnThePhoneIsPinnedWithItsRememberedModelAndEffort() throws {
        let result = try apply(.init(provider: "claude"))
        #expect(result.choices.value(for: AgentChatChoices.providerKey) == "claude")
        #expect(result.choices.value(for: "chat.model.claude") == "sonnet")
        #expect(result.choices.value(for: "chat.effort.claude") == "high")
        // And the app remembers it, as a window's pick makes it remember.
        #expect(result.remembered == ["reader.chat.provider": "claude"])
    }

    @Test func aModelAndEffortAreSetForTheChatsOwnProvider() throws {
        var choices = AgentChatChoices()
        choices.set("claude", for: AgentChatChoices.providerKey)
        let result = try apply(.init(model: "opus", effort: ""), to: choices)
        #expect(result.choices.value(for: "chat.model.claude") == "opus")
        // "" is the provider's default, kept as a choice.
        #expect(result.choices.value(for: "chat.effort.claude") == "")
        #expect(result.remembered == ["chat.model.claude": "opus", "chat.effort.claude": ""])
        // A chat with no provider of its own goes on the app's.
        let unpinned = try apply(.init(model: "gpt-5"))
        #expect(unpinned.choices.value(for: "chat.model.codex") == "gpt-5")
    }

    @Test func openCodesEffortIsWrittenOnItsModelAndRefusedWithoutOne() throws {
        var choices = AgentChatChoices()
        choices.set("openCode", for: AgentChatChoices.providerKey)
        choices.set("openai/gpt-5", for: "chat.model.openCode")
        let result = try apply(.init(effort: "high"), to: choices)
        #expect(result.choices.value(for: "chat.model.openCode") == "openai/gpt-5#high")
        #expect(result.choices.value(for: "chat.effort.openCode") == nil)

        choices.set("", for: "chat.model.openCode")
        #expect(throws: LampAgentRemoteHosting.ChoiceRefusal.effortNeedsModel) { try apply(.init(effort: "high"), to: choices) }
        // Taking it back to the default asks nothing of a model.
        #expect(try apply(.init(effort: ""), to: choices).choices.value(for: "chat.model.openCode") == "")
    }

    @Test func achatsChoicesAreShownAsItsMenusShowThem() {
        var choices = AgentChatChoices()
        choices.set("openai/gpt-5#low", for: "chat.model.openCode")
        let openCode = LampAgentRemoteHosting.chosen(in: choices, provider: .openCode, appDefault: { remembered[$0] })
        #expect(openCode.model == "openai/gpt-5" && openCode.effort == "low")
        // Nothing of its own: what the app remembers.
        let claude = LampAgentRemoteHosting.chosen(in: .init(), provider: .claude, appDefault: { remembered[$0] })
        #expect(claude.model == "sonnet" && claude.effort == "high")
        let codex = LampAgentRemoteHosting.chosen(in: .init(), provider: .codex, appDefault: { remembered[$0] })
        #expect(codex.model == "" && codex.effort == "")
    }

    @Test func aModelNamedWithTheChatsOwnProviderChangesOnlyTheModel() throws {
        var choices = AgentChatChoices()
        choices.set("claude", for: AgentChatChoices.providerKey)
        let result = try apply(.init(provider: "claude", model: "haiku"), to: choices)
        #expect(result.choices.value(for: "chat.model.claude") == "haiku")
        // Not a pick of provider: what new chats open on is left alone.
        #expect(result.remembered == ["chat.model.claude": "haiku"])
    }

    @Test func aModelChosenForAProviderTheChatHasLeftGoesBackToIt() throws {
        var choices = AgentChatChoices()
        choices.set("codex", for: AgentChatChoices.providerKey)
        let result = try apply(.init(provider: "claude", model: "opus"), to: choices)
        #expect(result.choices.value(for: AgentChatChoices.providerKey) == "claude")
        #expect(result.choices.value(for: "chat.model.claude") == "opus")
        #expect(result.choices.value(for: "chat.model.codex") == nil)
    }

    @Test func aNameNoProviderWouldUseIsRefused() throws {
        for name in ["--dangerously-skip-permissions", "high\" other=\"x", "a\\b", "gpt\n5", String(repeating: "x", count: 201)] {
            #expect(throws: LampAgentRemoteHosting.ChoiceRefusal.unusableName) { try apply(.init(model: name)) }
            #expect(throws: LampAgentRemoteHosting.ChoiceRefusal.unusableName) { try apply(.init(effort: name)) }
        }
        // What providers do name passes.
        for name in ["opus", "openai/gpt-5#high", "gemini-3.8-flash", "claude-sonnet-4-5-20250929", ""] {
            #expect(throws: Never.self) { try apply(.init(model: name)) }
        }
    }

    @Test func anUnknownProviderIsRefused() {
        #expect(throws: LampAgentRemoteHosting.ChoiceRefusal.unknownProvider) { try apply(.init(provider: "nobody")) }
    }

    @Test func aSetupProviderSaysWhatToTypeWhereItNamesNothing() {
        let connection = LampAgentRemoteSetup.Connection(state: LampAgentRemoteSetup.Connection.connected)
        let codex = LampAgentRemoteHosting.setupProvider(
            id: "codex", name: "OpenAI Codex", shortName: "Codex", systemImage: "terminal",
            wire: .codex, connection: connection, appDefault: { remembered[$0] }
        )
        #expect(codex.models.isEmpty && !codex.modelHint.isEmpty)
        #expect(codex.efforts.isEmpty && !codex.effortHint.isEmpty)
        let openCode = LampAgentRemoteHosting.setupProvider(
            id: "openCode", name: "OpenCode", shortName: "OpenCode", systemImage: nil,
            wire: .openCode, connection: connection, appDefault: { remembered[$0] }
        )
        #expect(openCode.effortIsOnTheModel)
        #expect(openCode.defaultModel == "anthropic/claude" && openCode.defaultEffort == "max")
        let claude = LampAgentRemoteHosting.setupProvider(
            id: "claude", name: "Claude Code", shortName: "Claude", systemImage: "sparkles",
            wire: .claude, connection: connection, appDefault: { remembered[$0] }
        )
        #expect(claude.models == ["opus", "sonnet", "haiku"])
        #expect(claude.defaultModel == "sonnet" && claude.defaultEffort == "high")
    }
}

struct LampAgentRemoteTailnetTests {
    @Test func listsIPv4FirstAndEachOnce() {
        #expect(LampAgentRemoteTailnet.ordered(["fd7a:115c:a1e0::1", "100.90.1.2", "fd7a:115c:a1e0::1", "100.90.1.2"])
            == ["100.90.1.2", "fd7a:115c:a1e0::1"])
    }

    @Test func offersOnlyTailnetAddressesWithTheListenersPort() {
        // Whatever this Mac's interfaces are, nothing outside Tailscale's
        // ranges is offered, and every address carries the port given.
        let addresses = LampAgentRemoteTailnet.addresses(port: 5000)
        #expect(addresses.allSatisfy { LampAgentRemoteAddress.isTailnet($0.host) && $0.port == 5000 })
    }
}
