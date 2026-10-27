// The dictionaries. This is the whole "intelligence" of the app: a fix is only suggested when the
// *other* reading of the keys is a real word, so names, brands and typos are never touched.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace LayoutFixer;

internal sealed class Dictionaries
{
    /// Rank in the English frequency list (0 = most common).
    private readonly Dictionary<string, int> _enRank = new();

    /// Rank in the Persian frequency list.
    private readonly Dictionary<string, int> _faRank = new();

    /// Every English word we know: the frequency list plus the words the user added.
    private readonly HashSet<string> _enAll = new(StringComparer.Ordinal);

    /// Only the most common Persian words count as a real reading; the long tail of the list is noisy.
    private const int FaLimit = 30000;

    public int EnglishWords => _enAll.Count;
    public int PersianWords => _faRank.Count;

    /// The word lists are embedded in the exe, so there is nothing to install next to it.
    public static Dictionaries Load()
    {
        var dicts = new Dictionaries();
        dicts.ReadResource("en_50k.txt", dicts._enRank);
        dicts.ReadResource("fa_50k.txt", dicts._faRank);

        foreach (var word in dicts._enRank.Keys) dicts._enAll.Add(word);
        dicts.ReadUserWords();
        return dicts;
    }

    private void ReadResource(string name, Dictionary<string, int> ranks)
    {
        using var stream = Resource.Open(name);
        if (stream == null) return;
        using var reader = new StreamReader(stream, Encoding.UTF8);
        ReadWords(reader, ranks, null);
    }

    /// Windows has no `/usr/share/dict/words`, which the macOS version uses for rare English words.
    /// A file the user owns plays the same role: `%LOCALAPPDATA%\LayoutFixer\words.txt`, one word
    /// per line — names, brands and jargon that must never be "fixed". It is read-only for the app.
    private void ReadUserWords()
    {
        var path = UserWordsPath;
        if (path == null) return;
        try
        {
            using var reader = new StreamReader(path, Encoding.UTF8);
            ReadWords(reader, null, _enAll);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public static string? UserWordsPath
    {
        get
        {
            var dir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (dir.Length == 0) return null;
            var path = Path.Combine(dir, "LayoutFixer", "words.txt");
            return File.Exists(path) ? path : null;
        }
    }

    private static void ReadWords(TextReader reader, Dictionary<string, int>? ranks, HashSet<string>? words)
    {
        var rank = 0;
        while (reader.ReadLine() is { } line)
        {
            // FrequencyWords lines look like "you 28787591"; a user file is one word per line.
            var space = line.IndexOf(' ');
            var word = Normalize(space < 0 ? line : line[..space]);
            if (word.Length > 0)
            {
                if (ranks != null && !ranks.ContainsKey(word)) ranks[word] = rank;
                words?.Add(word);
            }
            rank++;
        }
    }

    /// Lowercase, Arabic letters folded to their Persian forms, punctuation on both ends dropped.
    public static string Normalize(string s)
    {
        var builder = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            builder.Append(c switch
            {
                'ي' => 'ی',
                'ك' => 'ک',
                _ => c,
            });
        }
        var folded = builder.ToString().ToLowerInvariant();
        var start = 0;
        var end = folded.Length;
        while (start < end && IsDroppable(folded[start])) start++;
        while (end > start && IsDroppable(folded[end - 1])) end--;
        return folded[start..end];
    }

    private static bool IsDroppable(char c) => char.IsPunctuation(c) || char.IsSymbol(c) || char.IsWhiteSpace(c);

    private int? PersianRank(string s)
    {
        if (_faRank.TryGetValue(Normalize(s), out var rank) && rank < FaLimit) return rank;
        return null;
    }

    /// True when the word was typed on the wrong layout.
    /// `minLetters` guards against short words, which are often ambiguous ("شد" is "an" on English keys).
    /// `punctuation` lists the keys that are punctuation on an English layout but Persian letters;
    /// they can legitimately sit inside a mis-typed Persian word.
    public bool IsMistake(string typed, string typedLang, string converted, int minLetters = 3,
                         HashSet<char>? punctuation = null)
    {
        if (typedLang == "fa")
        {
            // Typed on Persian keys: the English reading must be a common English word, and more
            // common than the Persian word itself, in case the typed text really is Persian.
            var english = Normalize(converted);
            if (english.Length < minLetters) return false;
            foreach (var c in english) if (c > 127) return false;
            if (!_enRank.TryGetValue(english, out var en)) return false;
            var fa = PersianRank(typed);
            return fa == null || en < fa.Value;
        }

        // Typed on English keys: never touch a real English word, and only suggest Persian when the
        // Persian reading is a real Persian word.
        var word = Normalize(typed);
        if (word.Length < minLetters) return false;
        punctuation ??= new HashSet<char> { ',', ';', '\'', '[', ']' };
        var hasLetter = false;
        foreach (var c in word)
        {
            if (char.IsLetter(c))
            {
                hasLetter = true;
                continue;
            }
            if (!punctuation.Contains(c)) return false;
        }
        if (!hasLetter) return false;
        if (_enAll.Contains(word)) return false;
        // don't, it's, ...
        var apostrophe = word.IndexOf('\'');
        if (apostrophe > 0 && _enAll.Contains(word[..apostrophe])) return false;
        return PersianRank(converted) != null;
    }
}
