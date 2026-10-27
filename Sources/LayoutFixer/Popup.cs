// The popup. A small notice just under the caret that never takes focus and never swallows a click:
// it only tells you what Tab would do, and the keystrokes keep going to the app you are typing in.

using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace LayoutFixer;

internal sealed class Popup : Form
{
    private const int CS_DROPSHADOW = 0x00020000;

    private static readonly Color BackColorValue = Color.FromArgb(0xFF, 0x11, 0x1A, 0x19);
    private static readonly Color AccentColor = Color.FromArgb(0xFF, 0x2D, 0xD4, 0xBF);
    private static readonly Color TextColor = Color.FromArgb(0xFF, 0xF6, 0xFB, 0xFA);
    private static readonly Color DimColor = Color.FromArgb(0xFF, 0x9A, 0xA8, 0xA5);

    private const int MaxTextWidth = 620;   // logical pixels; scaled by the monitor's DPI
    private const float TitleSize = 15f;
    private const float HintSize = 11f;
    private const int PadX = 12;
    private const int PadY = 9;
    private const int Gap = 3;
    private const int Bar = 3;

    private readonly Timer _placeTimer;
    private Font _titleFont;
    private Font _hintFont;
    private double _scale = 1.0;

    private string _suggestion = "";
    private string _hint = "";
    private string _drawn = "";
    private bool _hasSuggestion;

    public Popup()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        MinimizeBox = false;
        MaximizeBox = false;
        ControlBox = false;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = BackColorValue;
        Text = "LayoutFixer";
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint
               | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);

        _titleFont = PixelFont(TitleSize, FontStyle.Bold);
        _hintFont = PixelFont(HintSize, FontStyle.Regular);

        // The app has not drawn the space we just saw yet, so wait a moment before looking for the caret.
        _placeTimer = new Timer { Interval = 40 };
        _placeTimer.Tick += (_, _) =>
        {
            _placeTimer.Stop();
            PlaceAndShow();
        };
    }

    private static Font PixelFont(float pixels, FontStyle style) => new("Segoe UI", pixels, style, GraphicsUnit.Pixel);

    /// True while a suggestion is on screen or on its way.
    public bool HasSuggestion => _hasSuggestion;

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _placeTimer.Dispose();
            _titleFont.Dispose();
            _hintFont.Dispose();
        }
        base.Dispose(disposing);
    }

    /// The popup must never become the active window: Tab has to arrive in the app being typed in.
    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ClassStyle |= CS_DROPSHADOW;
            cp.ExStyle |= Native.WS_EX_TOPMOST | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE
                        | Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED;
            cp.Layers = true;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        // A layered window stays invisible until its attributes are set; 255 means fully opaque.
        Native.SetLayeredWindowAttributes(Handle, 0, 255, Native.LWA_ALPHA);
        Native.ShowWindow(Handle, Native.SW_HIDE);
    }

    public void Present(string suggestion, string target)
    {
        if (suggestion.Length == 0)
        {
            Dismiss();
            return;
        }
        _suggestion = suggestion;
        _hint = $"Tab: fix & switch to {target}      ·      Esc: ignore";
        _hasSuggestion = true;
        _placeTimer.Stop();
        _placeTimer.Start();
    }

    public void Dismiss()
    {
        _placeTimer.Stop();
        if (!_hasSuggestion && !Visible) return;
        _hasSuggestion = false;
        if (Visible) Hide();
    }

    private void PlaceAndShow()
    {
        if (!_hasSuggestion) return;

        var anchor = CaretBottomLeft() ?? CursorPoint();
        var scale = Native.ScaleAt(anchor);
        if (Math.Abs(scale - _scale) > 0.01) ResizeFonts(scale);

        var size = Measure();
        var gap = (int)(6 * scale);
        var x = anchor.X;
        var y = anchor.Y + gap;

        var work = Screen.FromPoint(new Point(x, y)).WorkingArea;
        x = Math.Min(Math.Max(x, work.Left + 4), work.Right - size.Width - 4);
        // No room under the caret: put the popup above the line instead.
        if (y + size.Height > work.Bottom) y = anchor.Y - gap - (int)(22 * scale) - size.Height;
        y = Math.Max(y, work.Top + 4);

        if (!Visible) Visible = true;
        Native.SetWindowPos(Handle, Native.HWND_TOPMOST, x, y, size.Width, size.Height,
                            Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        if (_suggestion + "|" + _hint != _drawn) Invalidate();
    }

    private void ResizeFonts(double scale)
    {
        _scale = scale;
        _titleFont.Dispose();
        _hintFont.Dispose();
        _titleFont = PixelFont(TitleSize * (float)scale, FontStyle.Bold);
        _hintFont = PixelFont(HintSize * (float)scale, FontStyle.Regular);
    }

    /// The two lines of the popup, measured for a given text width. Both Measure and OnPaint go
    /// through here, so the window is always exactly as big as what it draws.
    private void MeasureLines(int maxWidth, out Size title, out Size hint)
    {
        title = TextRenderer.MeasureText(_suggestion, _titleFont, new Size(maxWidth, 0), Flags(_suggestion));
        hint = TextRenderer.MeasureText(_hint, _hintFont, new Size(maxWidth, 0), Flags(_hint));
    }

    private Size Measure()
    {
        var scale = (float)_scale;
        var limit = (int)(MaxTextWidth * _scale);
        MeasureLines(limit, out var title, out var hint);
        var margins = (int)((Bar + PadX) * 2 * scale);
        var width = Math.Max(title.Width, hint.Width) + margins;
        var height = title.Height + hint.Height + (int)(Gap * scale) + (int)(PadY * 2 * scale);
        return new Size(Math.Min(width, limit + margins), height);
    }

    private static TextFormatFlags Flags(string text)
    {
        var flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis;
        if (IsRightToLeft(text)) flags |= TextFormatFlags.RightToLeft;
        return flags;
    }

    /// Persian text has to be laid out right-to-left, or GDI puts the words in the wrong order.
    private static bool IsRightToLeft(string text)
    {
        foreach (var c in text)
        {
            if (c is >= 0x0590 and <= 0x08FF or >= 0xFB1D and <= 0xFEFF) return true;
            if (char.IsLetter(c)) return false;
        }
        return false;
    }

    protected override void OnPaintBackground(PaintEventArgs e) => e.Graphics.Clear(BackColorValue);

    protected override void OnPaint(PaintEventArgs e)
    {
        _drawn = _suggestion + "|" + _hint;
        var g = e.Graphics;
        var scale = (float)_scale;

        using (var accent = new SolidBrush(AccentColor))
            g.FillRectangle(accent, 0, 0, (int)(Bar * scale), Height);

        MeasureLines((int)(MaxTextWidth * _scale), out var title, out var hint);
        var left = (int)((Bar + PadX) * scale);
        var contentWidth = Math.Max(1, Width - left - (int)(PadX * scale));
        var titleRect = new Rectangle(left, (int)(PadY * scale), contentWidth, title.Height);
        var hintRect = new Rectangle(left, titleRect.Bottom + (int)(Gap * scale), contentWidth, hint.Height);

        TextRenderer.DrawText(g, _suggestion, _titleFont, titleRect, TextColor, BackColorValue, Flags(_suggestion));
        TextRenderer.DrawText(g, _hint, _hintFont, hintRect, DimColor, BackColorValue, TextFormatFlags.NoPadding);
    }

    private static Native.POINT CursorPoint()
    {
        return Native.GetCursorPos(out var pt) ? pt : new Native.POINT();
    }

    /// Bottom-left corner of the text caret of the foreground window, in screen pixels.
    private static Native.POINT? CaretBottomLeft()
    {
        var fg = Native.GetForegroundWindow();
        if (fg == IntPtr.Zero) return null;
        var thread = Native.GetWindowThreadProcessId(fg, out _);

        var info = new Native.GUITHREADINFO { CbSize = (uint)Marshal.SizeOf<Native.GUITHREADINFO>() };
        if (!Native.GetGUIThreadInfo(thread, ref info) || info.HwndCaret == IntPtr.Zero) return null;

        var caret = info.Caret;
        if (caret.Left == 0 && caret.Right == 0 && caret.Top == 0 && caret.Bottom == 0) return null;

        var top = new Native.POINT { X = caret.Left, Y = Math.Min(caret.Top, caret.Bottom) };
        var bottom = new Native.POINT { X = caret.Left, Y = Math.Max(caret.Top, caret.Bottom) };
        if (!Native.ClientToScreen(info.HwndCaret, ref bottom)) return null;
        Native.ClientToScreen(info.HwndCaret, ref top);

        // Most apps keep a zero-height caret rectangle; assume a normal line so the popup clears it.
        if (bottom.Y - top.Y < 4) bottom.Y = top.Y + (int)(Native.ScaleAt(bottom) * 20);
        return bottom;
    }
}
