// Keyboard layouts: the Windows counterpart of a macOS input source.
//
// A layout is an HKL. What we need from it is one thing: "this physical key (a scan code),
// with these modifiers, types this character". Both directions of the fix are built out of
// that single question, so the mapping is exact for whatever layouts the user has installed
// instead of a hardcoded English<->Persian table.

using System;
using System.Collections.Generic;
using System.Text;

namespace LayoutFixer;

internal sealed class Layout
{
    public IntPtr Hkl { get; }

    /// The HKL as hex: "04090409" for US English, "04290429" for Persian. Windows puts the language
    /// id in both words of an HKL, so this identifies the language, not the layout variant.
    public string Id { get; }

    /// "en" or "fa", from the primary language of the layout id.
    public string Lang { get; }

    public Layout(IntPtr hkl)
    {
        Hkl = hkl;
        // The low word of an HKL is the language id, the high word the layout (device) id,
        // which together are just the keyboard layout id (KLID).
        var words = (uint)(hkl.ToInt64() & 0xFFFF_FFFF);
        Id = words.ToString("x8");
        var primary = words & Native.PRIMARY_LANG_MASK;
        Lang = primary == Native.LANG_EN ? "en" : primary == Native.LANG_FA ? "fa" : "";
    }

    public string DisplayName => Lang == "fa" ? "فارسی" : "English";

    public bool IsSupported => Lang == "en" || Lang == "fa";

    /// Caps lock is part of the key state ToUnicodeEx reads, so it has to be reported every time.
    private static byte CapsLockState => (Native.GetKeyState(Native.VK_CAPITAL) & 1) != 0 ? (byte)1 : (byte)0;

    /// The character this layout produces for a physical key, or null when the key is not
    /// mapped to text (modifiers, dead keys, function keys, ...).
    public string? Character(uint vk, uint scan, bool shift, bool alt = false)
    {
        var state = new byte[256];
        if (shift) state[Native.VK_SHIFT] = 0x80;
        if (alt) state[Native.VK_MENU] = 0x80;
        state[Native.VK_CAPITAL] = CapsLockState;

        var buffer = new StringBuilder(8);
        // uFlags = 0x1 makes ToUnicodeEx skip dead-key translation. Two reasons we want that:
        // we get the bare character of the key (which is what a layout *means* for our purpose),
        // and, more importantly, probing never consumes the pending dead key of the layout the
        // user is typing in, so accent typing in other apps keeps working.
        var n = Native.ToUnicodeEx(vk, scan, state, buffer, 8, Native.DEAD_KEYS_ARE_NOT_TRANSLATED, Hkl);
        if (n <= 0) return null;
        return buffer.ToString(0, n);
    }

    /// The scan code this layout has for a virtual key (used by the --test mode, where the input
    /// is text and we have to find the physical key first).
    public uint ScanCode(uint vk) => Native.MapVirtualKeyEx(vk, Native.MAPVK_VK_TO_VSC, Hkl);

    public override string ToString() => $"{Lang}:{Id}";
}

internal static class Layouts
{
    /// The layout of the window that is being typed into right now. Not `GetKeyboardLayout(0)`:
    /// Windows keeps an input locale per thread, and our tray thread is not the one receiving keys.
    public static Layout? Current()
    {
        var fg = Native.GetForegroundWindow();
        IntPtr hkl;
        if (fg != IntPtr.Zero)
        {
            var thread = Native.GetWindowThreadProcessId(fg, out _);
            hkl = Native.GetKeyboardLayout(thread);
            if (hkl == IntPtr.Zero) hkl = Native.GetKeyboardLayout(0);
        }
        else
        {
            hkl = Native.GetKeyboardLayout(0);
        }
        return hkl == IntPtr.Zero ? null : new Layout(hkl);
    }

    /// The enabled layouts, one per language: English and Persian, whichever the user added. Two
    /// variants of one language (Persian and Persian-Standard) share an HKL, so one of them is used
    /// for the mapping; their letters agree, only punctuation and digits differ.
    public static Dictionary<string, Layout> Enabled(Layout? preferred = null)
    {
        var count = Native.GetKeyboardLayoutList(0, null);
        if (count <= 0) return new Dictionary<string, Layout>();
        var handles = new IntPtr[count];
        if (Native.GetKeyboardLayoutList(count, handles) <= 0) return new Dictionary<string, Layout>();

        var result = new Dictionary<string, Layout>();
        foreach (var hkl in handles)
        {
            var layout = new Layout(hkl);
            if (!layout.IsSupported) continue;
            // If there are two layouts for one language (US and UK, Persian and Persian-Standard),
            // keep the one being typed with: that is the one whose keys the taps actually use.
            if (!result.TryGetValue(layout.Lang, out var existing)
                || (preferred != null && layout.Hkl == preferred.Hkl && existing.Hkl != preferred.Hkl))
            {
                result[layout.Lang] = layout;
            }
        }
        return result;
    }

    /// The other half of the pair: Persian when you are typing English and the other way round.
    public static Layout? Other(Layout current, Dictionary<string, Layout> enabled)
    {
        if (!current.IsSupported) return null;
        return enabled.TryGetValue(current.Lang == "en" ? "fa" : "en", out var other) && other.Hkl != current.Hkl
            ? other
            : null;
    }

    /// Characters that are punctuation on one layout but letters on the other. On a US layout
    /// `, ; ' [ ]` are `و ک گ ج چ` on the Persian one, so those keys sit *inside* Persian words
    /// typed on English keys. Derived from the two layouts instead of hardcoded, so other English
    /// layouts (UK, Persian-Standard, ...) behave correctly too.
    public static HashSet<char> PunctuationThatMeansLetters(Layout from, Layout to)
    {
        var set = new HashSet<char>();
        for (uint vk = 0; vk < 255; vk++)
        {
            var scan = from.ScanCode(vk);
            if (scan == 0) continue;
            foreach (var shift in new[] { false, true })
            {
                var here = from.Character(vk, scan, shift);
                if (here == null || here.Length != 1) continue;
                var c = here[0];
                if (char.IsLetterOrDigit(c) || c == ' ') continue;
                var there = to.Character(vk, scan, shift);
                if (there != null && there.Length == 1 && char.IsLetter(there[0])) set.Add(c);
            }
        }
        return set;
    }

    /// Switch the focused app to `target`. Windows stores the input locale per thread, so a
    /// background app has to ask the foreground window to change; the direct activation is there
    /// for windows that ignore the request.
    public static void Activate(Layout target)
    {
        var fg = Native.GetForegroundWindow();
        if (fg == IntPtr.Zero)
        {
            Native.ActivateKeyboardLayout(target.Hkl, Native.KLF_REORDER);
            return;
        }

        Native.PostMessageW(fg, Native.WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, target.Hkl);

        var theirThread = Native.GetWindowThreadProcessId(fg, out _);
        var ourThread = Native.GetCurrentThreadId();
        if (theirThread != 0 && Native.AttachThreadInput(ourThread, theirThread, true))
        {
            Native.ActivateKeyboardLayout(target.Hkl, 0);
            Native.AttachThreadInput(ourThread, theirThread, false);
        }
    }
}
