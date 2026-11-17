# Third-party notices

## LAME MP3 encoder

MP3 output dynamically uses the bundled **LAME 3.100** library, © The LAME Project,
under GNU Library General Public License version 2 or later.

https://lame.sourceforge.io/

The complete license and matching original source archive are in `Vendor/LAME/`
in the source project, and `Contents/Resources/LAME/` in the installed app.
The encoder-only build changes the exported-symbol list to exclude unavailable
legacy/decoder functions; the encoding algorithms are unchanged. Rebuilding and
replacement instructions are included alongside the license. The app does not
restrict modification/replacement of the library or reverse engineering to debug
such modifications.

## m1ddc

The independent display-volume implementation consults/adapts DDC/CI packet
framing, IOAV interface declarations, and the MCDP29xx chip-address distinction
documented in **m1ddc**, by waydabber:

https://github.com/waydabber/m1ddc

Reference files: `headers/i2c.h`, `headers/ioregistry.h`, `sources/i2c.m`,
`sources/ioregistry.m`. The m1ddc executable is not bundled or installed.

The IOAV entry points are undocumented Apple interfaces. This feature is for
local learning/use and is not guaranteed to remain compatible with future macOS
versions. Unsupported or ambiguous configurations are reported rather than
silently routed to another display.

MIT License

Copyright (c) 2021 waydabber

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
