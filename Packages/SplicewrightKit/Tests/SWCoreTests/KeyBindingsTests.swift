import Foundation
import Testing
@testable import SWCore

@Suite("Key bindings")
struct KeyBindingsTests {
    @Test func defaultsAvoidMacOSShortcuts() {
        for command in CommandID.allCases {
            for input in KeyBindings.standard.inputs(for: command) {
                #expect(ReservedShortcuts.name(for: input) == nil, "\(command) uses \(input.displayString)")
            }
        }
    }

    @Test func defaultsAreUnique() {
        var seen: [KeyInput: CommandID] = [:]
        for command in CommandID.allCases {
            for input in KeyBindings.standard.inputs(for: command) {
                #expect(seen[input] == nil, "\(input.displayString) is bound to \(seen[input]!) and \(command)")
                seen[input] = command
            }
        }
    }

    @Test func exportIsNotMinimize() {
        let bindings = KeyBindings.standard
        #expect(bindings.inputs(for: .exportMedia) == [.character("e", [.command, .shift])])
        #expect(bindings.command(for: .character("m", .command)) == nil)
        #expect(ReservedShortcuts.name(for: .character("m", .command)) == "Minimize")
    }

    @Test func menuCommandsHaveNoPanelAction() {
        let bindings = KeyBindings.standard
        #expect(bindings.command(for: .character("i", .command)) == .importMedia)
        #expect(bindings.action(for: .character("i", .command)) == nil)
        #expect(bindings.action(for: .character("i")) == .markIn)
        #expect(CommandID.exportMedia.isMenuCommand)
        #expect(!CommandID.markIn.isMenuCommand)
    }

    @Test func assignMovesAShortcutFromAnotherCommand() {
        var bindings = KeyBindings()
        #expect(bindings.validate(.character("c"), for: .markIn) == .conflict(.toolRazor))
        let assigned = bindings.assign(.character("c"), to: .markIn)
        #expect(assigned)
        #expect(bindings.action(for: .character("c")) == .markIn)
        #expect(bindings.inputs(for: .toolRazor).isEmpty)
        #expect(bindings.inputs(for: .markIn) == [.character("i"), .character("c")])
        #expect(bindings.isCustomized(.markIn))
    }

    @Test func reservedShortcutsAreRefused() {
        var bindings = KeyBindings()
        #expect(bindings.validate(.character("q", .command), for: .markIn) == .reserved("Quit"))
        let assigned = bindings.assign(.character("H", .command), to: .markIn)
        #expect(!assigned)
        #expect(bindings.inputs(for: .markIn) == [.character("i")])
    }

    @Test func customPanelChordsWork() {
        var bindings = KeyBindings()
        bindings.assign(KeyInput(.rightArrow, [.control, .option]), to: .nextEditPoint)
        #expect(bindings.action(for: KeyInput(.rightArrow, [.control, .option])) == .nextEditPoint)
    }

    @Test func resetTakesDefaultsBack() {
        var bindings = KeyBindings()
        bindings.assign(.character("c"), to: .markIn)
        bindings.remove(.character("i"), from: .markIn)
        bindings.reset(.toolRazor)
        #expect(bindings.action(for: .character("c")) == .selectTool(.razor))
        #expect(bindings.inputs(for: .markIn).isEmpty)
        bindings.resetAll()
        #expect(bindings == KeyBindings.standard)
    }

    @Test func codableRoundTrip() throws {
        var bindings = KeyBindings()
        bindings.assign(.character("e", [.command, .option]), to: .exportMedia)
        bindings.assign(KeyInput(.home, .shift), to: .goToIn)
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode(KeyBindings.self, from: data) == bindings)
        #expect(String(data: data, encoding: .utf8)!.contains("exportMedia"))
    }

    @Test func displayStrings() {
        #expect(KeyInput.character("e", [.command, .shift]).displayString == "⇧⌘E")
        #expect(KeyInput(.leftArrow, [.option, .control]).displayString == "⌃⌥←")
        #expect(KeyInput(.space).displayString == "Space")
        #expect(KeyInput.character("x", .option).displayString == "⌥X")
    }

    @Test func everyCommandHasATitle() {
        for command in CommandID.allCases {
            #expect(command.title != command.rawValue, "\(command) has no title")
        }
    }
}
