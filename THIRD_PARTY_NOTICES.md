# Third-party notices

## Resources/en_50k.txt and Resources/fa_50k.txt

English and Persian word frequency lists from **FrequencyWords** by Hermit Dave
(https://github.com/hermitdave/FrequencyWords), files `content/2018/en/en_50k.txt` and
`content/2018/fa/fa_50k.txt`, derived from OpenSubtitles data.

Licensed under the Creative Commons Attribution-ShareAlike 4.0 International License
(https://creativecommons.org/licenses/by-sa/4.0/). The files are included unmodified and are embedded
into the exe as resources at build time. The MIT license of this project does not apply to these
files.

## Fonts

No font is shipped. The app uses the Segoe UI that is part of Windows for its popup, and the icon
and cover scripts render with whatever font is available on the machine that runs them (DejaVu Sans
on Linux, Segoe UI / Tahoma on Windows). The glyphs are baked into the .ico and .png files in this
repository; no font file is redistributed.

## Windows itself

The app is built on documented Win32 APIs (`SetWindowsHookEx`, `ToUnicodeEx`, `SendInput`,
`ActivateKeyboardLayout`, `GetGUIThreadInfo`). It contains no code copied from anywhere else, and no
third-party packages — the project has zero NuGet dependencies on purpose.
