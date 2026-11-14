import Foundation
import LampCore
import Testing
@testable import LampBibleMac

struct ReadAloudLanguageTests {
    @Test func aTranslationIsReadInTheLanguageItDeclares() {
        let spanish = LampInstalledModule(id: "RVR", kind: .translation, name: "Reina-Valera", language: "es")
        let undeclared = LampInstalledModule(id: "MINE", kind: .translation, name: "Mine")
        let blank = LampInstalledModule(id: "BLANK", kind: .translation, name: "Blank", language: " ")

        #expect(SpeechVoices.language(of: spanish) == "es")
        // As the importer assumes of a translation that names no language.
        #expect(SpeechVoices.language(of: undeclared) == SpeechVoices.english)
        #expect(SpeechVoices.language(of: blank) == SpeechVoices.english)
        #expect(SpeechVoices.language(of: nil) == SpeechVoices.english)
    }

    @Test func englishKeepsItsVoiceAndEachOtherLanguageHasItsOwn() {
        // The key quizzes and the dictionary's word speaker read too.
        #expect(SpeechVoices.voiceKey(for: "en-US") == "reader.readAloud.voice")
        #expect(SpeechVoices.voiceKey(for: "en_GB") == "reader.readAloud.voice")
        #expect(SpeechVoices.voiceKey(for: "es") == "reader.readAloud.voice.es")
        #expect(SpeechVoices.voiceKey(for: "es-MX") == "reader.readAloud.voice.es")
        #expect(SpeechVoices.voiceKey(for: "FR-fr") == "reader.readAloud.voice.fr")
    }

    @Test func biblicalLanguagesAreNamedAsAReaderKnowsThem() {
        #expect(SpeechVoices.languageName("grc") == "Greek")
        #expect(SpeechVoices.languageName("hbo") == "Hebrew")
        #expect(SpeechVoices.languageName("grc-x-koine") == "Greek")
        #expect(SpeechVoices.baseLanguage("fr_CA") == "fr")
    }
}
