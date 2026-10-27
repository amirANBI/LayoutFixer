// The hooks. One low-level keyboard hook does the watching, a mouse hook and a foreground
// notification say "the half-typed word is over, forget it".

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LayoutFixer;

internal sealed class InputHooks : IDisposable
{
    private readonly Fixer _fixer;
    private readonly Native.LowLevelHookProc _keyboard;
    private readonly Native.LowLevelHookProc _mouse;
    private readonly Native.WinEventProc _foreground;
    private IntPtr _keyboardHook;
    private IntPtr _mouseHook;
    private IntPtr _foregroundHook;

    // The Tab that accepted a fix is swallowed; its key-up has to disappear with it.
    private bool _swallowTabUp;

    public InputHooks(Fixer fixer)
    {
        _fixer = fixer;
        // Keep the delegates alive: they are passed to unmanaged code and must not be collected.
        _keyboard = OnKeyboard;
        _mouse = OnMouse;
        _foreground = OnForeground;
    }

    public bool Started => _keyboardHook != IntPtr.Zero;

    public void Start()
    {
        var module = Native.GetModuleHandleW(null);
        _keyboardHook = Native.SetWindowsHookExW(Native.WH_KEYBOARD_LL, _keyboard, module, 0);
        _mouseHook = Native.SetWindowsHookExW(Native.WH_MOUSE_LL, _mouse, module, 0);
        _foregroundHook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND,
                                                 IntPtr.Zero, _foreground, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
    }

    public void Stop()
    {
        if (_keyboardHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(_mouseHook);
        if (_foregroundHook != IntPtr.Zero) Native.UnhookWinEvent(_foregroundHook);
        _keyboardHook = _mouseHook = _foregroundHook = IntPtr.Zero;
    }

    public void Dispose() => Stop();

    private IntPtr OnKeyboard(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == Native.HC_ACTION)
        {
            var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            // Our own injected keystrokes come back through this hook: they are a fix, not typing.
            if (!info.ExtraInfo.Equals(Native.InjectedMarker))
            {
                var message = unchecked((int)wParam.ToInt64());
                if (message == Native.WM_KEYUP)
                {
                    if (_swallowTabUp && info.VkCode == Native.VK_TAB)
                    {
                        _swallowTabUp = false;
                        return new IntPtr(1);
                    }
                }
                else if (message == Native.WM_KEYDOWN || message == Native.WM_SYSKEYDOWN)
                {
                    // Ctrl/Alt combinations arrive as WM_SYSKEYDOWN; HandleKeyDown ends the word for them.
                    if (_fixer.HandleKeyDown(info.VkCode, info.ScanCode, info.Flags))
                    {
                        if (info.VkCode == Native.VK_TAB) _swallowTabUp = true;
                        return new IntPtr(1);
                    }
                }
            }
        }
        return Native.CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    private IntPtr OnMouse(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == Native.HC_ACTION)
        {
            var message = unchecked((int)wParam.ToInt64());
            if (message is Native.WM_LBUTTONDOWN or Native.WM_RBUTTONDOWN or Native.WM_MBUTTONDOWN) _fixer.Reset();
        }
        return Native.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    private void OnForeground(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint threadId,
                              uint eventTime) => _fixer.Reset();
}

internal static class Injector
{
    /// Removes the mis-typed characters and types the fix, as one batch so nothing can interleave.
    /// The text goes in as Unicode events, which is why the correction is right no matter which
    /// layout the keys came from. (Surrogate pairs are sent as two events, like Windows does.)
    public static void Retype(int backspaces, string text)
    {
        var inputs = new List<Native.INPUT>((backspaces + text.Length) * 2);
        var backScan = Native.MapVirtualKeyEx(Native.VK_BACK, Native.MAPVK_VK_TO_VSC, Native.GetKeyboardLayout(0));

        for (var i = 0; i < backspaces; i++)
        {
            inputs.Add(Key((ushort)Native.VK_BACK, backScan, 0));
            inputs.Add(Key((ushort)Native.VK_BACK, backScan, Native.KEYEVENTF_KEYUP));
        }
        foreach (var c in text)
        {
            inputs.Add(Key(0, c, Native.KEYEVENTF_UNICODE));
            inputs.Add(Key(0, c, Native.KEYEVENTF_UNICODE | Native.KEYEVENTF_KEYUP));
        }

        Native.SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<Native.INPUT>());
    }

    private static Native.INPUT Key(ushort vk, uint scan, uint flags) => new()
    {
        Type = Native.INPUT_KEYBOARD,
        Union = new Native.INPUTUNION
        {
            Keyboard = new Native.KEYBDINPUT
            {
                Vk = vk,
                Scan = (ushort)scan,
                Flags = flags,
                Time = 0,
                ExtraInfo = Native.InjectedMarker,
            },
        },
    };
}
