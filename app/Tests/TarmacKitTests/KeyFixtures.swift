@testable import TarmacKit

let shift: UInt = 1 << 17
let control: UInt = 1 << 18
let option: UInt = 1 << 19
let command: UInt = 1 << 20

func letter(_ c: Character, _ mods: UInt = 0) -> KeyPress {
    KeyPress(keyCode: 0, characters: String(c), charactersIgnoringModifiers: String(c), modifierFlags: mods)
}

func named(_ keyCode: UInt16, _ mods: UInt = 0) -> KeyPress {
    KeyPress(keyCode: keyCode, characters: "", charactersIgnoringModifiers: "", modifierFlags: mods)
}
