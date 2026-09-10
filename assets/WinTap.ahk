#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
#MenuMaskKey vkE8
; Pass physical Win-down through immediately. Only standalone short taps mask
; the menu before forwarding Win-up; no native Win combination is reimplemented.
global Presses := Map()
global Watcher := InputHook("V")
Watcher.KeyOpt("{All}", "N")
Watcher.OnKeyDown := OtherKey
Watcher.Start()
A_TrayMenu.Add("Exit Perfect Win11 helper", (*) => ExitApp())
A_IconTip := "Perfect Win11 - Win tap for Command Palette"

OtherKey(ih, vk, sc) {
    if (vk != 0x5B && vk != 0x5C)
        MarkUsed()
}
MarkUsed(*) {
    for key, info in Presses
        info.used := true
}
Down(key) {
    if Presses.Has(key)
        return
    used := Presses.Count > 0
    MarkUsed()
    ; A modifier or other key already held means this is not a standalone tap.
    Loop 254 {
        if (A_Index != 0x5B && A_Index != 0x5C && GetKeyState(Format("vk{:02X}", A_Index), "P")) {
            used := true
            break
        }
    }
    Presses[key] := {time: A_TickCount, used: used}
}
Up(key) {
    tap := false
    if Presses.Has(key) {
        info := Presses[key]
        tap := !info.used && A_TickCount - info.time <= 300
        Presses.Delete(key)
    }
    if tap
        SendEvent("{Blind}{vkE8}")
    SendEvent("{Blind}{" key " up}")
    if tap {
        ; PowerToys' own CmdPal show event; preserves customized activation shortcuts.
        handle := DllCall("OpenEventW", "UInt", 0x0002, "Int", false,
            "Str", "Local\PowerToysCmdPal-ShowEvent-62336fcd-8611-4023-9b30-091a6af4cc5a", "Ptr")
        if handle {
            DllCall("SetEvent", "Ptr", handle)
            DllCall("CloseHandle", "Ptr", handle)
        } else
            TrayTip("Enable Command Palette in PowerToys, then try again.", "Perfect Win11")
    }
}
~*LWin::Down("LWin")
~*RWin::Down("RWin")
*LWin Up::Up("LWin")
*RWin Up::Up("RWin")
~*LButton::MarkUsed()
~*RButton::MarkUsed()
~*MButton::MarkUsed()
~*XButton1::MarkUsed()
~*XButton2::MarkUsed()
~*WheelUp::MarkUsed()
~*WheelDown::MarkUsed()
