# 제3자 고지

DJCrate 배포물에 포함되거나 옮겨 온 코드의 출처와 라이선스 원문이다.

## SQLCipher.swift (4.19.0)

- 고지 기준 커밋: `39f212458aeb88e33bdac2200a793a3f0d55d32b`
- 출처: [sqlcipher/SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift/tree/39f212458aeb88e33bdac2200a793a3f0d55d32b)
- 원문: [LICENSE.md](https://github.com/sqlcipher/SQLCipher.swift/blob/39f212458aeb88e33bdac2200a793a3f0d55d32b/LICENSE.md)
- 가져오는 방법: 공식 4.19.0 `SQLCipher.xcframework.zip`을 `Package.swift`의 바이너리 타깃으로 직접 지정한다. 공식 패키지와 같은 URL·SHA-256 체크섬을 쓰며 프레임워크는 수정하지 않는다.
- DJCrate에서 쓰는 곳: `Sources/RekordboxKit/Database/CipherDatabase.swift`의 DB 접근과 앱에 포함하는 `SQLCipher.framework`.

````text
## Community Edition Open Source License

Copyright (c) 2025, ZETETIC LLC
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the ZETETIC LLC nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY ZETETIC LLC ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL ZETETIC LLC BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Begin SQLite README.md

<h1 align="center">SQLite Source Repository</h1>

This repository contains the complete source code for the
[SQLite database engine](https://sqlite.org/), including
many test scripts.  However, other test scripts
and most of the documentation are managed separately.

See the [on-line documentation](https://sqlite.org/) for more information
about what SQLite is and how it works from a user's perspective.  This
README file is about the source code that goes into building SQLite,
not about how SQLite is used.

## Version Control

SQLite sources are managed using
[Fossil](https://fossil-scm.org/), a distributed version control system
that was specifically designed and written to support SQLite development.
The [Fossil repository](https://sqlite.org/src/timeline) contains the urtext.

If you are reading this on GitHub or some other Git repository or service,
then you are looking at a mirror.  The names of check-ins and
other artifacts in a Git mirror are different from the official
names for those objects.  The official names for check-ins are
found in a footer on the check-in comment for authorized mirrors.
The official check-in name can also be seen in the `manifest.uuid` file
in the root of the tree.  Always use the official name, not  the
Git-name, when communicating about an SQLite check-in.

If you pulled your SQLite source code from a secondary source and want to
verify its integrity, there are hints on how to do that in the
[Verifying Code Authenticity](#vauth) section below.

## Contacting The SQLite Developers

The preferred way to ask questions or make comments about SQLite or to
report bugs against SQLite is to visit the 
[SQLite Forum](https://sqlite.org/forum) at <https://sqlite.org/forum/>.
Anonymous postings are permitted.

If you think you have found a bug that has security implications and
you do not want to report it on the public forum, you can send a private
email to drh at sqlite dot org.

## Public Domain

The SQLite source code is in the public domain.  See
<https://sqlite.org/copyright.html> for details. 

Because SQLite is in the public domain, we do not normally accept pull
requests, because if we did take a pull request, the changes in that
pull request might carry a copyright and the SQLite source code would
then no longer be fully in the public domain.

## Obtaining The SQLite Source Code

If you do not want to use Fossil, you can download tarballs or ZIP
archives or [SQLite archives](https://sqlite.org/cli.html#sqlar) as follows:

  *  Latest trunk check-in as
     [Tarball](https://www.sqlite.org/src/tarball/sqlite.tar.gz),
     [ZIP-archive](https://www.sqlite.org/src/zip/sqlite.zip), or
     [SQLite-archive](https://www.sqlite.org/src/sqlar/sqlite.sqlar).

  *  Latest release as
     [Tarball](https://www.sqlite.org/src/tarball/sqlite.tar.gz?r=release),
     [ZIP-archive](https://www.sqlite.org/src/zip/sqlite.zip?r=release), or
     [SQLite-archive](https://www.sqlite.org/src/sqlar/sqlite.sqlar?r=release).

  *  For other check-ins, substitute an appropriate branch name or
     tag or hash prefix in place of "release" in the URLs of the previous
     bullet.  Or browse the [timeline](https://www.sqlite.org/src/timeline)
     to locate the check-in desired, click on its information page link,
     then click on the "Tarball" or "ZIP Archive" links on the information
     page.

To access sources directly using [Fossil](https://fossil-scm.org/home),
first install Fossil version 2.0 or later.
Source tarballs and precompiled binaries available at
<https://fossil-scm.org/home/uv/download.html>.  Fossil is
a stand-alone program.  To install, simply download or build the single
executable file and put that file someplace on your $PATH.
Then run commands like this:

        mkdir -p ~/sqlite
        cd ~/sqlite
        fossil open https://sqlite.org/src

The "fossil open" command will take two or three minutes.  Afterwards,
you can do fast, bandwidth-efficient updates to the whatever versions
of SQLite you like.  Some examples:

        fossil update trunk             ;# latest trunk check-in
        fossil update release           ;# latest official release
        fossil update trunk:2024-01-01  ;# First trunk check-in after 2024-01-01
        fossil update version-3.39.0    ;# Version 3.39.0

Or type "fossil ui" to get a web-based user interface.

## Compiling for Unix-like systems

First create a directory in which to place
the build products.  It is recommended, but not required, that the
build directory be separate from the source directory.  Cd into the
build directory and then from the build directory run the configure
script found at the root of the source tree.  Then run "make".

For example:

        apt install gcc make tcl-dev  ;#  Make sure you have all the necessary build tools
        tar xzf sqlite.tar.gz         ;#  Unpack the source tree into "sqlite"
        mkdir bld                     ;#  Build will occur in a sibling directory
        cd bld                        ;#  Change to the build directory
        ../sqlite/configure           ;#  Run the configure script
        make sqlite3                  ;#  Builds the "sqlite3" command-line tool
        make sqlite3.c                ;#  Build the "amalgamation" source file
        make sqldiff                  ;#  Builds the "sqldiff" command-line tool
        # Makefile targets below this point require tcl-dev
        make tclextension-install     ;#  Build and install the SQLite TCL extension
        make devtest                  ;#  Run development tests
        make releasetest              ;#  Run full release tests
        make sqlite3_analyzer         ;#  Builds the "sqlite3_analyzer" tool

See the makefile for additional targets.  For debugging builds, the
core developers typically run "configure" with options like this:

        ../sqlite/configure --enable-all --enable-debug CFLAGS='-O0 -g'

For release builds, the core developers usually do:

        ../sqlite/configure --enable-all

Almost all makefile targets require a "tclsh" TCL interpreter version 8.6 or
later.  The "tclextension-install" target and the test targets that follow
all require TCL development libraries too.  ("apt install tcl-dev").  It is
helpful, but is not required, to install the SQLite TCL extension (the
"tclextension-install" target) prior to running tests.  The "releasetest"
target has additional requiremenst, such as "valgrind".

On "make" command-lines, one can add "OPTIONS=..." to specify additional
compile-time options over and above those set by ./configure.  For example,
to compile with the SQLITE_OMIT_DEPRECATED compile-time option, one could say:

        ./configure --enable-all
        make OPTIONS=-DSQLITE_OMIT_DEPRECATED sqlite3

The configure script uses autoconf 2.61 and libtool.  If the configure
script does not work out for you, there is a generic makefile named
"Makefile.linux-gcc" in the top directory of the source tree that you
can copy and edit to suit your needs.  Comments on the generic makefile
show what changes are needed.

## Compiling for Windows Using MSVC

On Windows, everything can be compiled with MSVC.
You will also need a working installation of TCL.
See the [compile-for-windows.md](doc/compile-for-windows.md) document for
additional information about how to install MSVC and TCL and configure your
build environment.

If you want to run tests, you need to let SQLite know the location of your
TCL library, using a command like this:

        set TCLDIR=c:\Tcl

SQLite uses "tclsh.exe" as part of the build process, and so that
program will need to be somewhere on your %PATH%.  SQLite itself
does not contain any TCL code, but it does use TCL to help with the
build process and to run tests.  You may need to install TCL development
libraries in order to successfully complete some makefile targets.
It is helpful, but is not required, to install the SQLite TCL extension
(the "tclextension-install" target) prior to running tests.

Build using Makefile.msc.  Example:

        nmake /f Makefile.msc sqlite3.exe
        nmake /f Makefile.msc sqlite3.c
        nmake /f Makefile.msc sqldiff.exe
        # Makefile targets below this point require TCL development libraries
        nmake /f Makefile.msc tclextension-install
        nmake /f Makefile.msc devtest
        nmake /f Makefile.msc releasetest
        nmake /f Makefile.msc sqlite3_analyzer.exe
 
There are many other makefile targets.  See comments in Makefile.msc for
details.

As with the unix Makefile, the OPTIONS=... argument can be passed on the nmake
command-line to enable new compile-time options.  For example:

        nmake /f Makefile.msc OPTIONS=-DSQLITE_OMIT_DEPRECATED sqlite3.exe

## Source Tree Map

  *  **src/** - This directory contains the primary source code for the
     SQLite core.  For historical reasons, C-code used for testing is
     also found here.  Source files intended for testing begin with "`test`".
     The `tclsqlite3.c` and `tclsqlite3.h` files are the TCL interface
     for SQLite and are also not part of the core.

  *  **test/** - This directory and its subdirectories contains code used
     for testing.  Files that end in "`.test`" are TCL scripts that run
     tests using an augmented TCL interpreter named "testfixture".  Use
     a command like "`make testfixture`" (unix) or 
     "`nmake /f Makefile.msc testfixture.exe`" (windows) to build that
     augmented TCL interpreter, then run individual tests using commands like
     "`testfixture test/main.test`".  This test/ subdirectory also contains
     additional C code modules and scripts for other kinds of testing.

  *  **tool/** - This directory contains programs and scripts used to
     build some of the machine-generated code that goes into the SQLite
     core, as well as to build and run tests and perform diagnostics.
     The source code to [the Lemon parser generator](./doc/lemon.html) is
     found here.  There are also TCL scripts used to build and/or transform
     source code files.  For example, the tool/mksqlite3h.tcl script reads
     the src/sqlite.h.in file and uses it as a template to construct
     the deliverable "sqlite3.h" file that defines the SQLite interface.

  *  **ext/** - Various extensions to SQLite are found under this
     directory.  For example, the FTS5 subsystem is in "ext/fts5/".
     Some of these extensions (ex: FTS3/4, FTS5, RTREE) might get built
     into the SQLite amalgamation, but not all of them.  The
     "ext/misc/" subdirectory contains an assortment of one-file extensions,
     many of which are omitted from the SQLite core, but which are included
     in the [SQLite CLI](https://sqlite.org/cli.html).
     
  *  **doc/** - Some documentation files about SQLite internals are found
     here.  Note, however, that the primary documentation designed for
     application developers and users of SQLite is in a completely separate
     repository.  Note also that the primary API documentation is derived
     from specially constructed comments in the src/sqlite.h.in file.

### Generated Source Code Files

Several of the C-language source files used by SQLite are generated from
other sources rather than being typed in manually by a programmer.  This
section will summarize those automatically-generated files.  To create all
of the automatically-generated files, simply run "make target&#95;source".
The "target&#95;source" make target will create a subdirectory "tsrc/" and
fill it with all the source files needed to build SQLite, both
manually-edited files and automatically-generated files.

The SQLite interface is defined by the **sqlite3.h** header file, which is
generated from src/sqlite.h.in, ./manifest.uuid, and ./VERSION.  The
[Tcl script](https://www.tcl.tk) at tool/mksqlite3h.tcl does the conversion.
The manifest.uuid file contains the SHA3 hash of the particular check-in
and is used to generate the SQLITE\_SOURCE\_ID macro.  The VERSION file
contains the current SQLite version number.  The sqlite3.h header is really
just a copy of src/sqlite.h.in with the source-id and version number inserted
at just the right spots. Note that comment text in the sqlite3.h file is
used to generate much of the SQLite API documentation.  The Tcl scripts
used to generate that documentation are in a separate source repository.

The SQL language parser is **parse.c** which is generated from a grammar in
the src/parse.y file.  The conversion of "parse.y" into "parse.c" is done
by the [lemon](./doc/lemon.html) LALR(1) parser generator.  The source code
for lemon is at tool/lemon.c.  Lemon uses the tool/lempar.c file as a
template for generating its parser.
Lemon also generates the **parse.h** header file, at the same time it
generates parse.c.

The **opcodes.h** header file contains macros that define the numbers
corresponding to opcodes in the "VDBE" virtual machine.  The opcodes.h
file is generated by scanning the src/vdbe.c source file.  The
Tcl script at ./mkopcodeh.tcl does this scan and generates opcodes.h.
A second Tcl script, ./mkopcodec.tcl, then scans opcodes.h to generate
the **opcodes.c** source file, which contains a reverse mapping from
opcode-number to opcode-name that is used for EXPLAIN output.

The **keywordhash.h** header file contains the definition of a hash table
that maps SQL language keywords (ex: "CREATE", "SELECT", "INDEX", etc.) into
the numeric codes used by the parse.c parser.  The keywordhash.h file is
generated by a C-language program at tool mkkeywordhash.c.

The **pragma.h** header file contains various definitions used to parse
and implement the PRAGMA statements.  The header is generated by a
script **tool/mkpragmatab.tcl**. If you want to add a new PRAGMA, edit
the **tool/mkpragmatab.tcl** file to insert the information needed by the
parser for your new PRAGMA, then run the script to regenerate the
**pragma.h** header file.

### The Amalgamation

All of the individual C source code and header files (both manually-edited
and automatically-generated) can be combined into a single big source file
**sqlite3.c** called "the amalgamation".  The amalgamation is the recommended
way of using SQLite in a larger application.  Combining all individual
source code files into a single big source code file allows the C compiler
to perform more cross-procedure analysis and generate better code.  SQLite
runs about 5% faster when compiled from the amalgamation versus when compiled
from individual source files.

The amalgamation is generated from the tool/mksqlite3c.tcl Tcl script.
First, all of the individual source files must be gathered into the tsrc/
subdirectory (using the equivalent of "make target_source") then the
tool/mksqlite3c.tcl script is run to copy them all together in just the
right order while resolving internal "#include" references.

The amalgamation source file is more than 200K lines long.  Some symbolic
debuggers (most notably MSVC) are unable to deal with files longer than 64K
lines.  To work around this, a separate Tcl script, tool/split-sqlite3c.tcl,
can be run on the amalgamation to break it up into a single small C file
called **sqlite3-all.c** that does #include on about seven other files
named **sqlite3-1.c**, **sqlite3-2.c**, ..., **sqlite3-7.c**.  In this way,
all of the source code is contained within a single translation unit so
that the compiler can do extra cross-procedure optimization, but no
individual source file exceeds 32K lines in length.

## How It All Fits Together

SQLite is modular in design.
See the [architectural description](https://www.sqlite.org/arch.html)
for details. Other documents that are useful in
helping to understand how SQLite works include the
[file format](https://www.sqlite.org/fileformat2.html) description,
the [virtual machine](https://www.sqlite.org/opcode.html) that runs
prepared statements, the description of
[how transactions work](https://www.sqlite.org/atomiccommit.html), and
the [overview of the query planner](https://www.sqlite.org/optoverview.html).

Decades of effort have gone into optimizing SQLite, both
for small size and high performance.  And optimizations tend to result in
complex code.  So there is a lot of complexity in the current SQLite
implementation.  It will not be the easiest library in the world to hack.

### Key source code files

  *  **sqlite.h.in** - This file defines the public interface to the SQLite
     library.  Readers will need to be familiar with this interface before
     trying to understand how the library works internally.  This file is
     really a template that is transformed into the "sqlite3.h" deliverable
     using a script invoked by the makefile.

  *  **sqliteInt.h** - this header file defines many of the data objects
     used internally by SQLite.  In addition to "sqliteInt.h", some
     subsystems inside of sQLite have their own header files.  These internal
     interfaces are not for use by applications.  They can and do change
     from one release of SQLite to the next.

  *  **parse.y** - This file describes the LALR(1) grammar that SQLite uses
     to parse SQL statements, and the actions that are taken at each step
     in the parsing process.  The file is processed by the
     [Lemon Parser Generator](./doc/lemon.html) to produce the actual C code
     used for parsing.

  *  **vdbe.c** - This file implements the virtual machine that runs
     prepared statements.  There are various helper files whose names
     begin with "vdbe".  The VDBE has access to the vdbeInt.h header file
     which defines internal data objects.  The rest of SQLite interacts
     with the VDBE through an interface defined by vdbe.h.

  *  **where.c** - This file (together with its helper files named
     by "where*.c") analyzes the WHERE clause and generates
     virtual machine code to run queries efficiently.  This file is
     sometimes called the "query optimizer".  It has its own private
     header file, whereInt.h, that defines data objects used internally.

  *  **btree.c** - This file contains the implementation of the B-Tree
     storage engine used by SQLite.  The interface to the rest of the system
     is defined by "btree.h".  The "btreeInt.h" header defines objects
     used internally by btree.c and not published to the rest of the system.

  *  **pager.c** - This file contains the "pager" implementation, the
     module that implements transactions.  The "pager.h" header file
     defines the interface between pager.c and the rest of the system.

  *  **os_unix.c** and **os_win.c** - These two files implement the interface
     between SQLite and the underlying operating system using the run-time
     pluggable VFS interface.

  *  **shell.c.in** - This file is not part of the core SQLite library.  This
     is the file that, when linked against sqlite3.a, generates the
     "sqlite3.exe" command-line shell.  The "shell.c.in" file is transformed
     into "shell.c" as part of the build process.

  *  **tclsqlite.c** - This file implements the Tcl bindings for SQLite.  It
     is not part of the core SQLite library.  But as most of the tests in this
     repository are written in Tcl, the Tcl language bindings are important.

  *  **test\*.c** - Files in the src/ folder that begin with "test" go into
     building the "testfixture.exe" program.  The testfixture.exe program is
     an enhanced Tcl shell.  The testfixture.exe program runs scripts in the
     test/ folder to validate the core SQLite code.  The testfixture program
     (and some other test programs too) is built and run when you type
     "make test".

  *  **VERSION**, **manifest**, and **manifest.uuid** - These files define
     the current SQLite version number.  The "VERSION" file is human generated,
     but the "manifest" and "manifest.uuid" files are automatically generated
     by the [Fossil version control system](https://fossil-scm.org/).

There are many other source files.  Each has a succinct header comment that
describes its purpose and role within the larger system.

<a name="vauth"></a>
## Verifying Code Authenticity

The `manifest` file at the root directory of the source tree
contains either a SHA3-256 hash or a SHA1 hash
for every source file in the repository.
The name of the version of the entire source tree is just the
SHA3-256 hash of the `manifest` file itself, possibly with the
last line of that file omitted if the last line begins with
"`# Remove this line`".
The `manifest.uuid` file should contain the SHA3-256 hash of the
`manifest` file. If all of the above hash comparisons are correct, then
you can be confident that your source tree is authentic and unadulterated.
Details on the format for the `manifest` files are available
[on the Fossil website](https://fossil-scm.org/home/doc/trunk/www/fileformat.wiki#manifest).

The process of checking source code authenticity is automated by the 
makefile:

>   make verify-source

Or on windows:

>   nmake /f Makefile.msc verify-source

Using the makefile to verify source integrity is good for detecting
accidental changes to the source tree, but malicious changes could be
hidden by also modifying the makefiles.

## Contacts

The main SQLite website is [https://sqlite.org/](https://sqlite.org/)
with geographically distributed backups at
[https://www2.sqlite.org/](https://www2.sqlite.org) and
[https://www3.sqlite.org/](https://www3.sqlite.org).

Contact the SQLite developers through the
[SQLite Forum](https://sqlite.org/forum/).  In an emergency, you
can send private email to the lead developer at drh at sqlite dot org.

````

## pyrekordbox (MIT)

- 고지 기준 커밋: `f695541827cc488af267d6ca8a8e0052598d85a0`
- 출처: [dylanljones/pyrekordbox](https://github.com/dylanljones/pyrekordbox/tree/f695541827cc488af267d6ca8a8e0052598d85a0)
- 원문: [LICENSE](https://github.com/dylanljones/pyrekordbox/blob/f695541827cc488af267d6ca8a8e0052598d85a0/LICENSE)
- DJCrate에서 쓰는 곳: `Sources/RekordboxKit/Database/RekordboxKey.swift`의 키 복원 절차와 OneLibrary(`exportLibrary.db`) 키 복원(`devicelib_plus/database.py`의 상수), `AnlzPreviewWaveform.swift`의 PWV4 채널·밝기 해석.
- 외부 파서 대조(`scripts/usb-parser-compare.py`, #189)는 임시 폴더에 받은 pyrekordbox(커밋 `5feacbce470621711785b6cb8f21420ca14a135d`)를 실행할 때 불러 OneLibrary를 읽는다. 코드는 옮기지 않고 배포하지 않는다.
- 인텔리전트 재생 목록(#68): `Sources/DJCDomain/Playlist/SmartPlaylist.swift`가 조건 칸(`djmdPlaylist.SmartList`)의 형식(커밋 `5feacbce470621711785b6cb8f21420ca14a135d`의 `pyrekordbox/masterdb/smartlist.py`와 `docs/source/formats/db6.md`)을 참고한다: NODE·CONDITION 칸 이름, 항목 이름(`PropertyName`) 목록, 연산자 번호 1~11, 결합 방식 번호 1·2. 파이썬 코드(SQLAlchemy 계산 포함)는 옮기지 않고 같은 형식을 Swift로 새로 썼다. 계산 의미는 이 자료를 따르지 않고 DJCrate가 정한다(`SmartPlaylistEvaluator`).

````text
MIT License

Copyright (c) 2022-2025, Dylan Jones

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

````

## baken (MIT)

- 고지 기준 커밋: `eecb4f798c661ac3a285ab1894ad4257ee923621`
- 출처: [M-Igashi/baken](https://github.com/M-Igashi/baken/tree/eecb4f798c661ac3a285ab1894ad4257ee923621)
- 원문: [LICENSE](https://github.com/M-Igashi/baken/blob/eecb4f798c661ac3a285ab1894ad4257ee923621/LICENSE)
- DJCrate에서 쓰는 곳: `Sources/RekordboxKit/Anlz/AnlzWaveform.swift`의 파형 규칙, `Sources/RekordboxKit/Usb/DeviceLibrary/PdbString.swift`(`PdbStringEncoder.encoded`)의 127자 이상 순수 ASCII 문자열 모양 선택.
- 파형 규칙 출처: [PR #148](https://github.com/M-Igashi/baken/pull/148)
- 문자열 규칙 참고: `crates/baken-export/src/pdb/string.rs`의 긴 문자열 처리(127자 이상 순수 ASCII 문자열을 UTF-16으로 쓰는 선택, 코드는 옮기지 않음)

````text
MIT License

Copyright (c) 2025 Masanari Higashi

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

````


## rekordbox_converter (MIT)

- 고지 기준 커밋: `b4cb8b0f7dece5f1b575d1f904c4bec3c67c62bc`
- 출처: [ModeAxe/rekordbox_converter](https://github.com/ModeAxe/rekordbox_converter/tree/b4cb8b0f7dece5f1b575d1f904c4bec3c67c62bc)
- 원문: [LICENSE](https://github.com/ModeAxe/rekordbox_converter/blob/b4cb8b0f7dece5f1b575d1f904c4bec3c67c62bc/LICENSE)
- DJCrate에서 쓰는 곳: `Sources/DJCDomain/Usb/UsbAnalysisNaming.swift`(`RekordboxAnalysisNaming`)의 USB 분석 파일 폴더 이름 계산(경로 해시의 곱수 0x5BC9·0x93B5, 나머지 200003, P 번호 비트).
- 규칙 참고: [PR #2](https://github.com/ModeAxe/rekordbox_converter/pull/2)의 `core/src/anlz.rs` `hash_audio_path`(계산 모양만 참고하고 코드는 옮기지 않음). rekordbox 7.2.x가 만든 USB 곡 708개와 CDJ-2000NXS가 만든 폴더 5개로 다시 확인했다(`docs/usb-internals.md` §5).

````text
MIT License

Copyright (c) 2026 xeadmo

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
````


## pyrekordbox — 프레이즈(PSSI) 마스크

- 기준 커밋: `f695541827cc488af267d6ca8a8e0052598d85a0`
- 출처: [dylanljones/pyrekordbox](https://github.com/dylanljones/pyrekordbox/tree/f695541827cc488af267d6ca8a8e0052598d85a0)
- 참고·이식 범위: `anlz/structs.py`의 PSSI 칸 배치, `anlz/file.py`의 XOR 마스크와 복원 규칙을 읽기 실험과 USB 내보내기에 사용한다. 쓰는 곳: `Sources/djc/Lab/PhraseStructure.swift`(실험용 읽기), `Sources/RekordboxKit/Usb/Anlz/AnlzMasks.swift`(USB 분석 파일의 PSSI 마스크·풀기).
- 라이선스: MIT. Python 패키지 자체는 배포하지 않는다.

```text
MIT License

Copyright (c) 2022-2025, Dylan Jones

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
```

## rekordcrate (MPL-2.0)

- 기준 커밋: `14d54eded7b0d2f6fe67c7871533dca35a73e5fa`
- 출처: [Holzhaus/rekordcrate](https://github.com/Holzhaus/rekordcrate/tree/14d54eded7b0d2f6fe67c7871533dca35a73e5fa)
- 원문: [COPYING](https://github.com/Holzhaus/rekordcrate/blob/14d54eded7b0d2f6fe67c7871533dca35a73e5fa/COPYING)
- 참고 범위: `src/pdb/ext.rs`의 `TagOrCategory`(먼 모양 My Tag 행의 문자열 오프셋 배열이 0x1C에서 시작)를 `Sources/RekordboxKit/Usb/DeviceLibrary/PdbRows.swift`(`PdbRows.tag`)의 칸 자리 근거로 참고했다. 코드는 옮기지 않았다.
- 외부 파서 대조(`scripts/usb-parser-compare.py`, #189)는 임시 폴더에서 빌드한 rekordcrate 실행 파일(`dump-pdb --format json`)을 부른다. 배포하지 않는다.

````text
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
````

## Crate Digger — rekordbox export 분석 문서 (EPL-2.0)

- 기준 커밋: `7c9d5358d8a3ce663f566380f2dc79ab1393201e`
- 출처: [Deep-Symmetry/crate-digger `doc/modules/ROOT/pages/exports.adoc`](https://github.com/Deep-Symmetry/crate-digger/blob/7c9d5358d8a3ce663f566380f2dc79ab1393201e/doc/modules/ROOT/pages/exports.adoc)(게시본: [djl-analysis.deepsymmetry.org](https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/exports.html))
- 원문: [LICENSE](https://github.com/Deep-Symmetry/crate-digger/blob/7c9d5358d8a3ce663f566380f2dc79ab1393201e/LICENSE)
- 참고 범위: "Tag Rows" 절의 먼 모양(0684) 칸 자리(이름 오프셋 0x1E–0x1F, 두 번째 글자 오프셋이 그 뒤 두 바이트)를 `PdbRows.tag`의 근거로 참고했다. 문서 원문과 코드는 옮기지 않았다.

````text
Eclipse Public License - v 2.0

    THE ACCOMPANYING PROGRAM IS PROVIDED UNDER THE TERMS OF THIS ECLIPSE
    PUBLIC LICENSE ("AGREEMENT"). ANY USE, REPRODUCTION OR DISTRIBUTION
    OF THE PROGRAM CONSTITUTES RECIPIENT'S ACCEPTANCE OF THIS AGREEMENT.

Secondary Licenses: This Source Code may also be made available under
the following Secondary Licenses when the conditions for such
availability set forth in the Eclipse Public License, v. 2.0 are
satisfied: Mozilla Public License 2.0,
https://www.mozilla.org/en-US/MPL/2.0/ or GNU Lesser General Public
License 3, https://opensource.org/licenses/LGPL-3.0

1. DEFINITIONS

"Contribution" means:

  a) in the case of the initial Contributor, the initial content
     Distributed under this Agreement, and

  b) in the case of each subsequent Contributor:
     i) changes to the Program, and
     ii) additions to the Program;
  where such changes and/or additions to the Program originate from
  and are Distributed by that particular Contributor. A Contribution
  "originates" from a Contributor if it was added to the Program by
  such Contributor itself or anyone acting on such Contributor's behalf.
  Contributions do not include changes or additions to the Program that
  are not Modified Works.

"Contributor" means any person or entity that Distributes the Program.

"Licensed Patents" mean patent claims licensable by a Contributor which
are necessarily infringed by the use or sale of its Contribution alone
or when combined with the Program.

"Program" means the Contributions Distributed in accordance with this
Agreement.

"Recipient" means anyone who receives the Program under this Agreement
or any Secondary License (as applicable), including Contributors.

"Derivative Works" shall mean any work, whether in Source Code or other
form, that is based on (or derived from) the Program and for which the
editorial revisions, annotations, elaborations, or other modifications
represent, as a whole, an original work of authorship.

"Modified Works" shall mean any work in Source Code or other form that
results from an addition to, deletion from, or modification of the
contents of the Program, including, for purposes of clarity any new file
in Source Code form that contains any contents of the Program. Modified
Works shall not include works that contain only declarations,
interfaces, types, classes, structures, or files of the Program solely
in each case in order to link to, bind by name, or subclass the Program
or Modified Works thereof.

"Distribute" means the acts of a) distributing or b) making available
in any manner that enables the transfer of a copy.

"Source Code" means the form of a Program preferred for making
modifications, including but not limited to software source code,
documentation source, and configuration files.

"Secondary License" means either the GNU General Public License,
Version 3.0, or any later versions of that license, including any
exceptions or additional permissions as identified by the initial
Contributor.

2. GRANT OF RIGHTS

  a) Subject to the terms of this Agreement, each Contributor hereby
  grants Recipient a non-exclusive, worldwide, royalty-free copyright
  license to reproduce, prepare Derivative Works of, publicly display,
  publicly perform, Distribute and sublicense the Contribution of such
  Contributor, if any, and such Derivative Works.

  b) Subject to the terms of this Agreement, each Contributor hereby
  grants Recipient a non-exclusive, worldwide, royalty-free patent
  license under Licensed Patents to make, use, sell, offer to sell,
  import and otherwise transfer the Contribution of such Contributor,
  if any, in Source Code or other form. This patent license shall
  apply to the combination of the Contribution and the Program if, at
  the time the Contribution is added by the Contributor, such addition
  of the Contribution causes such combination to be covered by the
  Licensed Patents. The patent license shall not apply to any other
  combinations which include the Contribution. No hardware per se is
  licensed hereunder.

  c) Recipient understands that although each Contributor grants the
  licenses to its Contributions set forth herein, no assurances are
  provided by any Contributor that the Program does not infringe the
  patent or other intellectual property rights of any other entity.
  Each Contributor disclaims any liability to Recipient for claims
  brought by any other entity based on infringement of intellectual
  property rights or otherwise. As a condition to exercising the
  rights and licenses granted hereunder, each Recipient hereby
  assumes sole responsibility to secure any other intellectual
  property rights needed, if any. For example, if a third party
  patent license is required to allow Recipient to Distribute the
  Program, it is Recipient's responsibility to acquire that license
  before distributing the Program.

  d) Each Contributor represents that to its knowledge it has
  sufficient copyright rights in its Contribution, if any, to grant
  the copyright license set forth in this Agreement.

  e) Notwithstanding the terms of any Secondary License, no
  Contributor makes additional grants to any Recipient (other than
  those set forth in this Agreement) as a result of such Recipient's
  receipt of the Program under the terms of a Secondary License
  (if permitted under the terms of Section 3).

3. REQUIREMENTS

3.1 If a Contributor Distributes the Program in any form, then:

  a) the Program must also be made available as Source Code, in
  accordance with section 3.2, and the Contributor must accompany
  the Program with a statement that the Source Code for the Program
  is available under this Agreement, and informs Recipients how to
  obtain it in a reasonable manner on or through a medium customarily
  used for software exchange; and

  b) the Contributor may Distribute the Program under a license
  different than this Agreement, provided that such license:
     i) effectively disclaims on behalf of all other Contributors all
     warranties and conditions, express and implied, including
     warranties or conditions of title and non-infringement, and
     implied warranties or conditions of merchantability and fitness
     for a particular purpose;

     ii) effectively excludes on behalf of all other Contributors all
     liability for damages, including direct, indirect, special,
     incidental and consequential damages, such as lost profits;

     iii) does not attempt to limit or alter the recipients' rights
     in the Source Code under section 3.2; and

     iv) requires any subsequent distribution of the Program by any
     party to be under a license that satisfies the requirements
     of this section 3.

3.2 When the Program is Distributed as Source Code:

  a) it must be made available under this Agreement, or if the
  Program (i) is combined with other material in a separate file or
  files made available under a Secondary License, and (ii) the initial
  Contributor attached to the Source Code the notice described in
  Exhibit A of this Agreement, then the Program may be made available
  under the terms of such Secondary Licenses, and

  b) a copy of this Agreement must be included with each copy of
  the Program.

3.3 Contributors may not remove or alter any copyright, patent,
trademark, attribution notices, disclaimers of warranty, or limitations
of liability ("notices") contained within the Program from any copy of
the Program which they Distribute, provided that Contributors may add
their own appropriate notices.

4. COMMERCIAL DISTRIBUTION

Commercial distributors of software may accept certain responsibilities
with respect to end users, business partners and the like. While this
license is intended to facilitate the commercial use of the Program,
the Contributor who includes the Program in a commercial product
offering should do so in a manner which does not create potential
liability for other Contributors. Therefore, if a Contributor includes
the Program in a commercial product offering, such Contributor
("Commercial Contributor") hereby agrees to defend and indemnify every
other Contributor ("Indemnified Contributor") against any losses,
damages and costs (collectively "Losses") arising from claims, lawsuits
and other legal actions brought by a third party against the Indemnified
Contributor to the extent caused by the acts or omissions of such
Commercial Contributor in connection with its distribution of the Program
in a commercial product offering. The obligations in this section do not
apply to any claims or Losses relating to any actual or alleged
intellectual property infringement. In order to qualify, an Indemnified
Contributor must: a) promptly notify the Commercial Contributor in
writing of such claim, and b) allow the Commercial Contributor to control,
and cooperate with the Commercial Contributor in, the defense and any
related settlement negotiations. The Indemnified Contributor may
participate in any such claim at its own expense.

For example, a Contributor might include the Program in a commercial
product offering, Product X. That Contributor is then a Commercial
Contributor. If that Commercial Contributor then makes performance
claims, or offers warranties related to Product X, those performance
claims and warranties are such Commercial Contributor's responsibility
alone. Under this section, the Commercial Contributor would have to
defend claims against the other Contributors related to those performance
claims and warranties, and if a court requires any other Contributor to
pay any damages as a result, the Commercial Contributor must pay
those damages.

5. NO WARRANTY

EXCEPT AS EXPRESSLY SET FORTH IN THIS AGREEMENT, AND TO THE EXTENT
PERMITTED BY APPLICABLE LAW, THE PROGRAM IS PROVIDED ON AN "AS IS"
BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR
IMPLIED INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS OF
TITLE, NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A PARTICULAR
PURPOSE. Each Recipient is solely responsible for determining the
appropriateness of using and distributing the Program and assumes all
risks associated with its exercise of rights under this Agreement,
including but not limited to the risks and costs of program errors,
compliance with applicable laws, damage to or loss of data, programs
or equipment, and unavailability or interruption of operations.

6. DISCLAIMER OF LIABILITY

EXCEPT AS EXPRESSLY SET FORTH IN THIS AGREEMENT, AND TO THE EXTENT
PERMITTED BY APPLICABLE LAW, NEITHER RECIPIENT NOR ANY CONTRIBUTORS
SHALL HAVE ANY LIABILITY FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING WITHOUT LIMITATION LOST
PROFITS), HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OR DISTRIBUTION OF THE PROGRAM OR THE
EXERCISE OF ANY RIGHTS GRANTED HEREUNDER, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGES.

7. GENERAL

If any provision of this Agreement is invalid or unenforceable under
applicable law, it shall not affect the validity or enforceability of
the remainder of the terms of this Agreement, and without further
action by the parties hereto, such provision shall be reformed to the
minimum extent necessary to make such provision valid and enforceable.

If Recipient institutes patent litigation against any entity
(including a cross-claim or counterclaim in a lawsuit) alleging that the
Program itself (excluding combinations of the Program with other software
or hardware) infringes such Recipient's patent(s), then such Recipient's
rights granted under Section 2(b) shall terminate as of the date such
litigation is filed.

All Recipient's rights under this Agreement shall terminate if it
fails to comply with any of the material terms or conditions of this
Agreement and does not cure such failure in a reasonable period of
time after becoming aware of such noncompliance. If all Recipient's
rights under this Agreement terminate, Recipient agrees to cease use
and distribution of the Program as soon as reasonably practicable.
However, Recipient's obligations under this Agreement and any licenses
granted by Recipient relating to the Program shall continue and survive.

Everyone is permitted to copy and distribute copies of this Agreement,
but in order to avoid inconsistency the Agreement is copyrighted and
may only be modified in the following manner. The Agreement Steward
reserves the right to publish new versions (including revisions) of
this Agreement from time to time. No one other than the Agreement
Steward has the right to modify this Agreement. The Eclipse Foundation
is the initial Agreement Steward. The Eclipse Foundation may assign the
responsibility to serve as the Agreement Steward to a suitable separate
entity. Each new version of the Agreement will be given a distinguishing
version number. The Program (including Contributions) may always be
Distributed subject to the version of the Agreement under which it was
received. In addition, after a new version of the Agreement is published,
Contributor may elect to Distribute the Program (including its
Contributions) under the new version.

Except as expressly stated in Sections 2(a) and 2(b) above, Recipient
receives no rights or licenses to the intellectual property of any
Contributor under this Agreement, whether expressly, by implication,
estoppel or otherwise. All rights in the Program not expressly granted
under this Agreement are reserved. Nothing in this Agreement is intended
to be enforceable by any entity that is not a Contributor or Recipient.
No third-party beneficiary rights are created under this Agreement.

Exhibit A - Form of Secondary Licenses Notice

"This Source Code may also be made available under the following
Secondary Licenses when the conditions for such availability set forth
in the Eclipse Public License, v. 2.0 are satisfied: {name license(s),
version(s), and exceptions or additional permissions here}."

  Simply including a copy of this Agreement, including this Exhibit A
  is not sufficient to license the Source Code under Secondary Licenses.

  If it is not possible or desirable to put the notice in a particular
  file, then You may include the notice in a location (such as a LICENSE
  file in a relevant directory) where a recipient would be likely to
  look for such a notice.

  You may add additional accurate notices of copyright ownership.
````
