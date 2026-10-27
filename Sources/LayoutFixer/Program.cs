// LayoutFixer for Windows — notices words typed in the wrong keyboard layout (English <-> Persian),
// shows a small popup under the caret, and on Tab retypes them and switches the layout.
//
// This file is the app itself: the tray icon, the menu, the things Windows needs that macOS does
// not (a hidden window to run deferred work in, a registry entry for login, an exe-wide mutex).

using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace LayoutFixer;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--test") return TestMode.Run(args[1]);

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        // Two instances would mean two hooks and two fixes for the same word.
        using var singleInstance = new Mutex(true, @"Local\LayoutFixer.SingleInstance", out var isFirst);
        if (!isFirst)
        {
            MessageBox.Show("LayoutFixer is already running in the system tray.", "LayoutFixer",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        using (var app = new TrayApp())
        {
            Application.Run(app);
        }
        return 0;
    }
}

internal sealed class TrayApp : ApplicationContext
{
    private readonly Popup _popup;
    private readonly Fixer _fixer;
    private readonly InputHooks _hooks;
    private readonly WorkWindow _work;
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _enabledItem;
    private readonly ToolStripMenuItem _autostartItem;
    private readonly Icon _iconOn;
    private readonly Icon _iconPaused;

    public TrayApp()
    {
        _popup = new Popup();
        _fixer = new Fixer(Dictionaries.Load(), _popup) { IsPasswordField = PasswordBox.IsFocused };
        _fixer.FixRequested += QueueFix;

        // The fix itself runs on the message loop: see QueueFix.
        _work = new WorkWindow();
        _work.FixRequested += ApplyFix;

        _hooks = new InputHooks(_fixer);
        _hooks.Start();

        _iconOn = LoadIcon("TrayIcon.ico");
        _iconPaused = LoadIcon("TrayIconPaused.ico");

        _statusItem = new ToolStripMenuItem("LayoutFixer") { Enabled = false, ForeColor = Color.Gray };
        _enabledItem = new ToolStripMenuItem("Enabled") { Checked = true };
        _enabledItem.Click += (_, _) => SetEnabled(!_enabledItem.Checked);
        _autostartItem = new ToolStripMenuItem("Start with Windows") { Checked = Autostart.IsEnabled() };
        _autostartItem.Click += (_, _) => ToggleAutostart();
        var quit = new ToolStripMenuItem("Quit LayoutFixer", null, (_, _) => ExitThread());

        var menu = new ContextMenuStrip();
        menu.Items.AddRange(new ToolStripItem[]
        {
            _statusItem, new ToolStripSeparator(), _enabledItem, _autostartItem, new ToolStripSeparator(), quit,
        });
        menu.Opening += (_, _) => UpdateStatus();

        _icon = new NotifyIcon
        {
            Icon = _iconOn,
            Text = "LayoutFixer",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.MouseDoubleClick += (_, _) => SetEnabled(!_enabledItem.Checked);
        _icon.BalloonTipTitle = "LayoutFixer is running";
        _icon.BalloonTipText = _hooks.Started
            ? "Press Tab to fix a word typed in the wrong layout. Right-click the tray icon for options."
            : "Windows refused the keyboard hook, so nothing is watched yet. A window that runs as " +
              "administrator only accepts input from an elevated LayoutFixer.";
        _icon.ShowBalloonTip(6000);

        UpdateStatus();
    }

    /// The hook callback has to be fast and must not inject input while it runs, so accepting a
    /// suggestion is posted to our own window and happens on the next turn of the message loop.
    private void QueueFix() => _work.RequestFix();

    private void ApplyFix() => _fixer.Apply();

    private void SetEnabled(bool enabled)
    {
        _fixer.Enabled = enabled;
        _fixer.Reset();
        _enabledItem.Checked = enabled;
        _icon.Icon = enabled ? _iconOn : _iconPaused;
        UpdateStatus();
    }

    private void ToggleAutostart()
    {
        try
        {
            Autostart.Set(!_autostartItem.Checked);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "LayoutFixer", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        _autostartItem.Checked = Autostart.IsEnabled();
    }

    private void UpdateStatus()
    {
        var layouts = Layouts.Enabled(Layouts.Current());
        var hasEnglish = layouts.ContainsKey("en");
        var hasPersian = layouts.ContainsKey("fa");

        _statusItem.Visible = !_hooks.Started || !hasEnglish || !hasPersian;
        if (_statusItem.Visible)
        {
            _statusItem.Text = !_hooks.Started
                ? "Keyboard hook refused — nothing is watched"
                : !hasPersian
                    ? "Add a Persian keyboard layout in Settings first"
                    : "Add an English keyboard layout in Settings first";
        }
        _icon.Text = _fixer.Enabled
            ? "LayoutFixer" + (_hooks.Started ? "" : " — not running")
            : "LayoutFixer — paused";
    }

    private static Icon LoadIcon(string name)
    {
        var size = Math.Max(16, SystemInformation.SmallIconSize.Width);
        using var stream = Resource.Open(name);
        if (stream == null) return SystemIcons.Application;
        // Pick the frame that matches the tray, so the icon is never resampled by the shell.
        return new Icon(stream, size, size);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _icon.Visible = false;
            _icon.Dispose();
            _hooks.Dispose();
            _work.Dispose();
            _fixer.Dispose();
            _popup.Dispose();
            _iconOn.Dispose();
            _iconPaused.Dispose();
        }
        base.Dispose(disposing);
    }
}

/// A hidden window whose only job is to receive a message from the keyboard hook. WinForms needs a
/// real window to hand work to the message loop, and a low-level hook callback is the wrong place to
/// inject keystrokes.
internal sealed class WorkWindow : NativeWindow, IDisposable
{
    private const int WmFixRequested = 0x8001; // WM_APP + 1
    private bool _disposed;

    public event Action? FixRequested;

    public WorkWindow() => CreateHandle(new CreateParams { Caption = "LayoutFixer worker" });

    public void RequestFix()
    {
        if (Handle != IntPtr.Zero) Native.PostMessageW(Handle, WmFixRequested, IntPtr.Zero, IntPtr.Zero);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WmFixRequested)
        {
            FixRequested?.Invoke();
            return;
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (Handle != IntPtr.Zero) DestroyHandle();
    }
}

/// Windows has no Secure Input, so the password case is handled the other way round: if the field
/// being typed into is a masked edit control, LayoutFixer forgets the keystrokes instead of watching.
/// (Browsers draw their own text, so there the buffer is only ever cleared by a click, a shortcut or
/// an app switch — and nothing is stored or sent in any case.)
internal static class PasswordBox
{
    private const int EsPassword = 0x0020;

    public static bool IsFocused()
    {
        var focus = Native.FocusOfForegroundWindow();
        if (focus == IntPtr.Zero) return false;
        if (Native.SendMessageW(focus, Native.EM_GETPASSWORDCHAR, IntPtr.Zero, IntPtr.Zero) != IntPtr.Zero) return true;
        return (Native.GetWindowLongW(focus, Native.GWL_STYLE) & EsPassword) != 0;
    }
}

internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "LayoutFixer";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, false);
            return key?.GetValue(ValueName) is string path
                   && string.Equals(path.Trim('"'), Environment.ProcessPath, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// HKCU\...\Run, so it stays in the user's own registry and is visible in Task Manager's
    /// "Startup apps" — no scheduled task, no service.
    public static void Set(bool on)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (key == null) throw new InvalidOperationException("Cannot open the login items registry key.");
        if (on) key.SetValue(ValueName, "\"" + Environment.ProcessPath + "\"");
        else key.DeleteValue(ValueName, false);
    }
}

/// Files the build embedded in the exe: the word lists and the icons. Nothing has to sit next to it.
internal static class Resource
{
    public static Stream? Open(string name)
    {
        var assembly = Assembly.GetExecutingAssembly();
        foreach (var full in assembly.GetManifestResourceNames())
        {
            if (full.EndsWith(name, StringComparison.OrdinalIgnoreCase)) return assembly.GetManifestResourceStream(full);
        }
        return null;
    }
}

/// Command-line test mode:  LayoutFixer.exe --test "فاهس هدسفثشی"
/// prints the same decision the app makes, without installing a hook or touching the focused window.
internal static class TestMode
{
    public static int Run(string text)
    {
        var console = AttachToConsole();
        try
        {
            return Detect(console, text);
        }
        finally
        {
            if (!ReferenceEquals(console, Console.Out)) console.Dispose();
        }
    }

    private static int Detect(TextWriter console, string text)
    {
        var dicts = Dictionaries.Load();
        var layouts = Layouts.Enabled(Layouts.Current());
        AddStockLayout(layouts, "en", "00000409");
        AddStockLayout(layouts, "fa", "00000429");

        var ids = new List<string>();
        foreach (var pair in layouts) ids.Add(pair.Key + "=" + pair.Value.Id);
        ids.Sort();
        console.WriteLine("layouts: " + string.Join(", ", ids));
        var userWords = Dictionaries.UserWordsPath;
        console.WriteLine("words: english=" + dicts.EnglishWords + " persian=" + dicts.PersianWords +
                          (userWords == null ? "" : " (+" + Path.GetFileName(userWords) + ")"));

        var typedInPersian = false;
        foreach (var c in text)
        {
            if (c >= 0x0600 && c <= 0x08FF) { typedInPersian = true; break; }
        }
        if (!layouts.TryGetValue(typedInPersian ? "fa" : "en", out var from)
            || !layouts.TryGetValue(typedInPersian ? "en" : "fa", out var to))
        {
            console.WriteLine("need both an English and a Persian layout enabled");
            return 1;
        }

        // Reverse map: character -> physical key, in the layout the text was typed on.
        var keyFor = new Dictionary<char, Key>();
        for (uint vk = 0; vk < 255; vk++)
        {
            var scan = from.ScanCode(vk);
            if (scan == 0) continue;
            foreach (var shift in new[] { false, true })
            {
                var character = from.Character(vk, scan, shift);
                if (character is { Length: 1 } && !keyFor.ContainsKey(character[0]))
                    keyFor[character[0]] = new Key(vk, scan, shift, character);
            }
        }

        var punctuation = Layouts.PunctuationThatMeansLetters(from, to);
        foreach (var word in text.Split(" ", StringSplitOptions.RemoveEmptyEntries))
        {
            var converted = new StringBuilder();
            foreach (var c in word)
            {
                // Keys this layout does not have are kept as they are, so the word stays readable.
                var key = keyFor.TryGetValue(c, out var found) ? found : new Key(0xFFFF, 0, false, c.ToString());
                converted.Append(to.Character(key.Vk, key.Scan, key.Shift) ?? key.Typed);
            }

            var reading = converted.ToString();
            var mistake = dicts.IsMistake(word, from.Lang, reading, 3, punctuation);
            var shortWord = dicts.IsMistake(word, from.Lang, reading, 1, punctuation);
            console.WriteLine(word + " -> " + reading + "  " +
                              (mistake ? "FIX" : shortWord ? "fix-if-next-is-wrong" : "ok"));
        }
        return 0;
    }

    /// The US and Persian layout tables ship with every Windows, so --test can be run — and checked
    /// in CI — on a machine where nobody added a Persian keyboard. The running app never uses this:
    /// it only ever suggests what the layouts you enabled can actually type.
    private static void AddStockLayout(Dictionary<string, Layout> layouts, string lang, string klid)
    {
        if (layouts.ContainsKey(lang)) return;
        var hkl = Native.LoadKeyboardLayoutW(klid, Native.KLF_SUBSTITUTE_OK);
        if (hkl == IntPtr.Zero) return;
        var layout = new Layout(hkl);
        if (layout.Lang == lang) layouts[lang] = layout;
    }

    /// A windowless exe starts without a console, so output goes nowhere unless we borrow the console
    /// of whatever launched us — or make one, when started from Explorer. A parent that redirected us
    /// to a file or a pipe already gave us usable standard handles, and those win.
    private static TextWriter AttachToConsole()
    {
        var standard = Native.GetStdHandle(Native.STD_OUTPUT_HANDLE);
        if (standard != IntPtr.Zero && standard != new IntPtr(-1))
        {
            var type = Native.GetFileType(standard);
            if (type == Native.FILE_TYPE_DISK || type == Native.FILE_TYPE_PIPE) return Console.Out;
        }
        if (!Native.AttachConsole(Native.ATTACH_PARENT_PROCESS) && !Native.AllocConsole()) return Console.Out;
        var handle = Native.CreateFileW("CONOUT$", Native.GENERIC_WRITE,
                                       Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE,
                                       IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) return Console.Out;
        // The FileStream owns the handle from here on, and closes it with the writer.
        return new StreamWriter(new FileStream(handle, FileAccess.Write), new UTF8Encoding(false)) { AutoFlush = true };
    }
}
