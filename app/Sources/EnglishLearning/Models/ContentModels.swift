import Foundation
import SwiftData

@Model
final class Word {
    var id: UUID
    var text: String
    var phonetic: String
    var meaningChinese: String
    var audioURL: String
    var imageURL: String

    init(text: String, phonetic: String = "", meaningChinese: String,
         audioURL: String = "", imageURL: String = "") {
        self.id = UUID()
        self.text = text
        self.phonetic = phonetic
        self.meaningChinese = meaningChinese
        self.audioURL = audioURL
        self.imageURL = imageURL
    }
}

@Model
final class Sentence {
    var id: UUID
    var text: String
    var meaningChinese: String
    var audioURL: String

    init(text: String, meaningChinese: String, audioURL: String = "") {
        self.id = UUID()
        self.text = text
        self.meaningChinese = meaningChinese
        self.audioURL = audioURL
    }
}
