https://www.youtube.com/watch?v=Gv2I7qTux7g

Andrew Kelley’s talk explains why Zig exists, how it “fixes C,” and what makes it practical for writing high‑reliability systems software.

He starts by contrasting safety in fields like aviation and elevators with the fragility of software, arguing that most mainstream languages make it too easy to write unreliable programs. From there he narrows the options down to C (and low‑level languages) but points out C’s fundamental problems: ⁠#include⁠ and the preprocessor as a separate language, difficult‑to‑control compilation, reliance on macros, and pervasive undefined behavior that makes writing robust code hard.

The core of the talk is how Zig addresses these issues while staying in C’s “systems” niche. He removes the preprocessor and instead makes “everything an expression” that can be evaluated at compile time. This leads to a powerful ⁠comptime⁠ model: you can run ordinary functions during compilation, assert invariants at compile time, and even implement features like ⁠printf⁠‑style format checking and generics entirely in Zig, without special compiler magic. Types are also expressions, so passing types to ⁠comptime⁠ parameters naturally yields generic code.

Next he focuses on error handling as a first‑class concern. In C, the “laziest” code path ignores errors and often appears to succeed while silently failing. In Zig, ignoring errors doesn’t compile: functions that may fail use an error union type, ⁠try⁠ propagates errors conveniently, and the runtime produces detailed error return traces that show where an error originated and how it propagated. For crashes and assertions, Zig provides rich stack traces across platforms, making diagnosis much easier.

He then shows how Zig simplifies resource cleanup. Where C code needs messy nested ⁠if⁠/⁠goto⁠ patterns to free resources in all error paths, Zig uses ⁠defer⁠ and ⁠errdefer⁠ so that resources are cleaned up automatically when scope exits (normally or via error). This keeps allocations and deallocations local and linear, avoiding “spaghetti” cleanup logic.

Kelley introduces error sets, where a function’s possible error values form a typed set. When you ⁠catch⁠ an error and ⁠switch⁠ on it, the compiler forces you to handle all possible cases and warns if you handle impossible ones. This makes adding new error variants a deliberate, API‑breaking change and ensures downstream code revisits error handling when behavior changes.

Finally, he covers Zig’s build system and C integration. Traditional C projects accumulate a tangle of build tools (autotools, Make, shell scripts, CMake, external libraries). Zig instead provides a built‑in, cross‑platform build system written in Zig (⁠build.zig⁠) and ships with everything needed to build its own dependencies. Because Zig already embeds libclang to parse C headers, it can act as a C compiler (⁠zig cc⁠), with better defaults, automatic caching, dependency tracking, and cross‑compilation. Zig ships with libc headers and implementations (musl, glibc startup files), so it can build and cross‑compile both Zig and C programs to many targets from a single toolchain.

He closes by emphasizing that all of this already exists in current Zig releases, credits community support (especially via Patreon) for enabling him to work full‑time on Zig, and briefly compares Zig to Rust: goals are aligned (safer, better systems software), but Zig aims for a simpler model, explicit allocation (no default allocator or GC), and a “C replacement” feel, accepting more responsibility on the programmer while offering strong tooling (comptime, error traces, build system) to keep quality high.

https://www.youtube.com/watch?v=YXrb-DqsBNU

The talk introduces Zig as a simple, low-level systems language and a C/C++ toolchain designed to improve software robustness, performance, and long‑term maintainability.

What Zig Is Trying To Do

Andrew Kelley explains that Zig is both a general-purpose programming language and toolchain aimed at “maintaining robust, optimal, reusable software.” He positions Zig as a way to “clean under the rug” of software: making memory allocation explicit (passing allocators instead of assuming a global one), not always depending on libc, and raising the quality bar of everyday software (like banks and healthcare systems).

Zig is also the foundation for tools like ⁠zig cc⁠, a drop‑in C/C++ compiler with safer defaults and good cross‑compilation support.

Zig’s Motto: “Maintain It with Zig”

He presents a three‑level “adoption ladder”:

1. Level 1 – Use Zig as a C/C++ compiler (⁠zig cc⁠)

 ▫ Drop‑in replacement used at companies like Uber for hermetic builds (reproducible, not depending on system toolchains).

 ▫ Enables undefined behavior sanitizer by default, finding real bugs in existing C/C++ code in the wild.

 ▫ Makes cross‑compilation trivial: one flag to target Windows, Linux, macOS, specific glibc versions, or static binaries with musl.

 ▫ Has built‑in caching, so large C projects can be built with one command line listing ⁠.c⁠ files, and incremental rebuilds become very fast.

 ▫ Installation is a small zip download, contrasting with the heavy experience of installing something like Visual Studio.

2. Level 2 – Use the Zig build system

 ▫ Replace complex build setups (Make + CMake, recursive Makefiles, etc.) with a single ⁠build.zig⁠ file.

 ▫ The build script is written in Zig, so builds are declarative but programmable.

 ▫ Custom build steps and flags (like a ⁠play⁠ step for running a game) appear automatically in the CLI help.

 ▫ Planned next step: fulfill C/C++ dependencies through Zig’s build system so collaborators don’t need fragile system setups.

3. Level 3 – Write components in Zig

 ▫ Once you depend on Zig for builds, you can start adding Zig code itself.

 ▫ He shows an example where C and Zig call each other:

 ⁃ Zig exports a function to dump stack traces and a function that sums an array.

 ⁃ C calls into those, and Zig’s runtime and C code share a stack trace with frames from both languages.

 ▫ Link‑time optimization (LTO) lets Zig and C interopt so tightly that, in an optimized build, a Zig function can be fully optimized away and replaced by a constant.

Nonprofit vs VC: “Predicting the Future”

Mid‑talk, he shifts to organizational structure and long‑term reliability:

- He contrasts nonprofits (profit must be reinvested into a mission) with for‑profit, especially VC‑backed startups, whose success criteria are maximizing returns for owners.

- He sketches a typical VC timeline: seductive product, then investor pressure, then acquisition or growth into a big corporation with misaligned incentives for users over time.

- Compares Wikipedia (nonprofit) to Google (for‑profit): both beloved early on, but diverging reputations decades later.

- He highlights issues with acquisitions of solid private businesses (like his dad’s roofing company or Rad Game Tools being bought by Epic), implying that great technical products often decay when sold.

- He notes SQLite as a good private model (consortium funding), but still vulnerable when founders retire or sell.

From this, he argues that Zig Software Foundation is a 501(c)(3) nonprofit, which:

- Has achieved financial stability (revenues exceed expenses).

- Reinvests surplus by paying contributors aligned with the mission.

- Has no VC pressure, no runway clock, and is governed by a board, not just Andrew, so the project’s mission is stable beyond any one person.

Zig “In the Wild”

He then surveys where Zig is used effectively:

- Low-level infrastructure

 ▫ Examples like the River Wayland window manager demonstrate Zig’s suitability for system components.

- High-performance runtimes and libraries

 ▫ Bun (JavaScript runtime) credits Zig’s low‑level control and lack of hidden control flow for its speed.

 ▫ Native libraries used from higher‑level languages, e.g. Ziggler for Elixir NIFs, where Zig integrates smoothly with BEAM code.

 ▫ Visual effects (VFX) plugins: using Zig to procedurally generate assets (like sand) to save huge bandwidth/memory in studio pipelines.

- High-performance applications & games

 ▫ Andrew’s own digital audio workstation project (a “white whale” he started in C++ and tried in Rust before creating Zig).

 ▫ The Mach game engine and related graphics tools.

 ▫ zig‑gamedev demos: PBR rendering, physics, audio.

 ▫ TigerBeetle, a high‑performance financial accounting database written in Zig, marketed as the “world’s fastest” in its category.

- Resource-constrained and embedded environments

 ▫ Embedded store controller project that ran for months with zero reported bugs.

 ▫ The Zig Embedded Group, with ⁠microzig⁠ as a unified HAL over several microcontrollers.

 ▫ Experimental OS projects like Box OS, using Zig as a systems language.

 ▫ WebAssembly games and fantasy consoles where Zig is popular because it generates efficient, small binaries suited to constrained environments.

A Taste of Zig (Language Features)

In the last third, he gives quick language‑level “tastes”:

- ArrayList implementation

 ▫ Demonstrates how generic containers are implemented: functions that take a type and return a type, using simple, orthogonal features.

 ▫ Emphasis that Zig’s semantics keep you focused on application logic instead of complex language rules or macro systems.

- Inline loops & reflection

 ▫ Example: a generic debug ⁠dump⁠ function using reflection over struct fields.

 ▫ An ⁠inline for⁠ over ⁠@typeInfo⁠ fields effectively unrolls the loop at compile time, so the compiler knows each field at compile time and can print arbitrary structs with very little code.

- Hash maps and sets (AutoArrayHashMap)

 ▫ A hash map that preserves insertion order (like Python 3 dicts) and automatically derives hash & equality via reflection.

 ▫ API is high-level: ⁠put⁠, ⁠get⁠, ⁠getOrPut⁠ (“upsert”), and the layout keeps keys and values in dense arrays.

 ▫ Using ⁠void⁠ as the value type yields a set instead of a map with zero overhead for values.

 ▫ The testing framework detects memory leaks by tracking allocations and reporting where memory wasn’t freed, improving safety during development.

- MultiArrayList and Data-Oriented Design

 ▫ A container that represents a struct-of-arrays: one array per field, improving cache behavior in some patterns.

 ▫ The real implementation is only a few hundred lines, relying mostly on the same inline loops and reflection ideas.

 ▫ Sorting it requires coordinated swaps across multiple arrays, implemented elegantly in Zig using a context struct and a generic sort function (more type‑safe and expressive than C’s ⁠void*⁠‑based callbacks).

- C Integration Demo

 ▫ Shows a small roguelike deckbuilder that uses C libraries like SDL, SDL_ttf, and stb_image via Zig’s C interop.

 ▫ C APIs look familiar but gain Zig niceties like ⁠defer⁠ for cleanup.

 ▫ Build script logic chooses between system libraries for native builds and vendored C sources for cross‑compilation, so you can reliably target Windows from Linux/macOS without requiring your collaborators to install special SDKs.

Closing Points

He ends by reinforcing three main ideas:

- Zig Software Foundation is a nonprofit whose mission is to improve the craft of software engineering industry‑wide, not just for Zig users.

- Zig as a toolchain can benefit existing C/C++ projects via better defaults, cross‑compilation, robust caching, and a programmable build system—even if you never write a line of Zig.

- Zig as a language is simple but powerful, particularly strong where performance, predictability, and tight control over memory and binaries matter, and adoption is growing across many domains.