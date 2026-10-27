// The tracker: watches the keys you type, decides when a run of words looks like the wrong layout,
// keeps the popup in sync, and on Tab hands the corrected text to the injector.

using System;
using System.Collections.Generic;
using System.Text;
using System.Windows.Forms;

namespace LayoutFixer;

/// One physical keypress: where it is on the keyboard (scan code) and what it typed.
internal readonly struct Key
{
    public Key(uint vk, uint scan, bool shift, string typed)
    {
        Vk = vk;
        Scan = scan;
        Shift = shift;
        Typed = typed;
    }

    public uint Vk { get; }
    public uint Scan { get; }
    public bool Shift { get; }
    public string Typed { get; }
}

internal sealed class Fixer : IDisposable
{
    private const int HideAfterMs = 10_000;
    private const int MaxRunWords = 12;

    private readonly Dictionaries _dicts;
    private readonly Popup _popup;
    private readonly Timer _hideTimer;

    /// The word being typed right now.
    private readonly List<Key> _word = new();

    /// The word finished just before _word, when only a single space separates them.
    private readonly List<Key> _previous = new();

    /// Keystrokes from the first wrong word up to now, while the popup is showing.
    private readonly List<Key> _run = new();

    private Layout? _current;
    private Layout? _other;
    private HashSet<char> _punctuation = new();
    private string? _runLayoutId;
    private int _runWords;
    private bool _fixQueued;

    public Fixer(Dictionaries dicts, Popup popup)
    {
        _dicts = dicts;
        _popup = popup;
        _hideTimer = new Timer { Interval = HideAfterMs };
        _hideTimer.Tick += (_, _) => Reset();
    }

    public bool Enabled { get; set; } = true;

    /// Raised from the hook; the app runs the actual fix on the message loop, because a
    /// low-level hook callback has to return fast and must not inject input while it runs.
    public event Action? FixRequested;

    /// While this returns true the foreground window is a password box: nothing is remembered.
    public Func<bool>? IsPasswordField { get; set; }

    /// True while a fix is on offer: there is a run of wrong keys and the popup shows them.
    public bool HasSuggestion => _run.Count > 0 && _popup.HasSuggestion;

    public void Dispose() => _hideTimer.Dispose();

    public void Reset()
    {
        _word.Clear();
        _previous.Clear();
        _run.Clear();
        _runLayoutId = null;
        _runWords = 0;
        _fixQueued = false;
        _hideTimer.Stop();
        _popup.Dismiss();
    }

    /// Returns true when the keystroke must be swallowed (only ever the Tab that accepts a fix).
    public bool HandleKeyDown(uint vk, uint scan, uint hookFlags)
    {
        if (!Enabled) return false;
        if (IsPasswordField?.Invoke() == true) { Reset(); return false; }

        var shift = (Native.GetAsyncKeyState(Native.VK_SHIFT) & 0x8000) != 0;
        var shortcut = (Native.GetAsyncKeyState(Native.VK_CONTROL) & 0x8000) != 0
                    || (hookFlags & Native.LLKHF_ALTDOWN) != 0
                    || (Native.GetAsyncKeyState(Native.VK_LWIN) & 0x8000) != 0;
        // Ctrl/Alt/Win means a shortcut, and a shortcut moves the caret somewhere else.
        if (shortcut) { Reset(); return false; }

        switch (vk)
        {
            case Native.VK_TAB:
                if (HasSuggestion)
                {
                    if (!_fixQueued)
                    {
                        _fixQueued = true;
                        FixRequested?.Invoke();
                    }
                    return true;
                }
                Reset();
                return false;

            case Native.VK_ESCAPE:
            case Native.VK_RETURN:
            case Native.VK_DELETE:
            case Native.VK_LEFT:
            case Native.VK_RIGHT:
            case Native.VK_UP:
            case Native.VK_DOWN:
            case Native.VK_HOME:
            case Native.VK_END:
            case Native.VK_PRIOR:
            case Native.VK_NEXT:
                Reset();
                return false;

            case Native.VK_BACK:
                if (_word.Count > 0) _word.RemoveAt(_word.Count - 1);
                if (_run.Count > 0)
                {
                    _run.RemoveAt(_run.Count - 1);
                    if (_run.Count == 0) Reset(); else RefreshPopup();
                }
                return false;

            case Native.VK_SPACE:
                var space = new Key(vk, scan, false, " ");
                if (_run.Count > 0) _run.Add(space);
                FinishWord(space);
                return false;

            default:
                // Shift, Ctrl, Alt, Caps Lock and friends are neither part of a word nor a reason
                // to forget the word that is being typed.
                if (Array.IndexOf(Native.IgnoredKeys, (int)vk) >= 0) return false;

                var current = CurrentLayout();
                if (current == null) { Reset(); return false; }
                var typed = current.Character(vk, scan, shift);
                if (typed == null || HasControlCharacter(typed)) { Reset(); return false; }
                _word.Add(new Key(vk, scan, shift, typed));
                if (_run.Count > 0)
                {
                    _run.Add(new Key(vk, scan, shift, typed));
                    RefreshPopup();
                }
                return false;
        }
    }

    private static bool HasControlCharacter(string s)
    {
        foreach (var c in s) if (char.IsControl(c)) return true;
        return false;
    }

    /// The layout of the window being typed into, refreshed on every keystroke: switching layouts
    /// mid-sentence has to end the run we are following. While there is no partner layout at all
    /// (no Persian keyboard yet) this keeps looking, so the app starts working the moment one is added.
    private Layout? CurrentLayout()
    {
        var current = Layouts.Current();
        if (current == null) return null;
        if (_current != null && _current.Hkl == current.Hkl && _other != null) return _current;

        _current = current;
        _other = null;
        _punctuation = new HashSet<char>();
        if (current.IsSupported)
        {
            var other = Layouts.Other(current, Layouts.Enabled(current));
            if (other != null)
            {
                _other = other;
                _punctuation = Layouts.PunctuationThatMeansLetters(current, other);
            }
        }
        return _current;
    }

    private void FinishWord(Key space)
    {
        var finished = new List<Key>(_word);
        var before = new List<Key>(_previous);   // the word before this one, without its space
        _word.Clear();
        _previous.Clear();
        _previous.AddRange(finished);
        if (finished.Count == 0) return;

        var current = _current;
        var other = _other;
        if (current == null || other == null) return;

        if (_run.Count > 0)
        {
            // Already showing a suggestion: keep extending it, unless the layout changed underneath us.
            _runWords++;
            if (current.Id != _runLayoutId || _runWords > MaxRunWords) Reset(); else RefreshPopup();
            return;
        }

        if (LooksWrong(finished, current, other, MinLetters))
        {
            // A short word just before (like "هد" -> "in") is usually part of the same mistake.
            _run.Clear();
            if (LooksWrong(before, current, other, 1))
            {
                _run.AddRange(before);
                _run.Add(space);
            }
            _run.AddRange(finished);
            // The space just pressed belongs to the run too: the app will insert it, so the fix has
            // to delete it and type it back, or the word ends up in front of a stray space.
            _run.Add(space);
            _runLayoutId = current.Id;
            _runWords = 1;
            RefreshPopup();
        }
    }

    private const int MinLetters = 3;

    private bool LooksWrong(List<Key> keys, Layout current, Layout other, int minLetters)
    {
        if (keys.Count == 0) return false;
        return _dicts.IsMistake(Typed(keys), current.Lang, ConvertTo(keys, other), minLetters, _punctuation);
    }

    private static string Typed(List<Key> keys)
    {
        var builder = new StringBuilder();
        foreach (var key in keys) builder.Append(key.Typed);
        return builder.ToString();
    }

    /// Reads the same physical keys through the other layout. Exact, because it is the same
    /// translation Windows itself does when a key is pressed.
    private static string ConvertTo(List<Key> keys, Layout layout)
    {
        var builder = new StringBuilder();
        foreach (var key in keys)
        {
            if (key.Vk == Native.VK_SPACE)
            {
                builder.Append(' ');
                continue;
            }
            builder.Append(layout.Character(key.Vk, key.Scan, key.Shift) ?? key.Typed);
        }
        return builder.ToString();
    }

    private Layout? TargetLayout()
    {
        var current = CurrentLayout();
        return current == null ? null : Layouts.Other(current, Layouts.Enabled(current));
    }

    private void RefreshPopup()
    {
        var target = TargetLayout();
        if (target == null) return;
        var suggestion = ConvertTo(_run, target).Trim();
        _popup.Present(suggestion, target.DisplayName);
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    /// Accepts the suggestion: removes the mis-typed run and retypes it in the right language.
    public void Apply()
    {
        if (_run.Count == 0) { _fixQueued = false; return; }
        var target = TargetLayout();
        if (target == null) { Reset(); return; }

        var text = ConvertTo(_run, target);
        var deletes = 0;
        foreach (var key in _run) deletes += key.Typed.Length;
        Reset();
        _fixQueued = false;

        Layouts.Activate(target);
        Injector.Retype(deletes, text);
    }
}
