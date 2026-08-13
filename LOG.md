# Daily Log

## 08-12-2026

V1, and the all-element test finally running

- Built V1 from `d39c82c4` and it works. It embeds AudioFileProcessor instruments AND Sample
  tracks, not just AudioFileProcessor, using only attributes stock LMMS already understands
- ⚠️ **an apostrophe in the path stops a full build dead.** The drive is `Amine's External 6TN 1`
  and LMMS's ZynAddSubFx rule escapes the spaces but not the quote, so the shell dies on an
  unterminated string. `make lmms` is fine because it never runs that codegen; packaging is not,
  because cpack runs `make all`. Fixed with a symlink that has no apostrophe in it. Third time that
  same apostrophe broke something

The native option cannot make a 1.2 file, which was the whole original point

- Checked two files our own build saved: `midiclip`, `mixer`, `mixerchannel`, `automationclip`, and
  zero `srcdata`. LMMS 1.3 writes 1.3 element names on every save, so 1.2 cannot parse them at all
- That has nothing to do with embedding and cannot be fixed by changing it. The 1.2 path stays with
  `web/lmms-sample-embedder.html` in the relinker repo, which writes `srcdata` too
- ⚠️ **do not round-trip a grader-bound project through this build.** Open a 1.2 project here, save,
  and it is 1.3 now and will not go back

Adding a CLI

- Embedding was GUI only, so testing it meant driving a window and doing one project at a time.
  Added `lmms embedsamples <in> <out>`, mirroring `makebundle`
- **It segfaulted on the very first run.** `embedResources()` reads the engine sample rate and CLI
  commands never start an audio engine, so the pointer is null. The GUI path could never have shown
  this
- Failure now names the sample it could not read. Before, the only clue was "failed to embed
  samples", which is no help when the culprit is something like the `samples/empty.wav` that ships
  in LMMS's own DirtyLove demo
- ⚠️ that demo is a real reproducer: embedding refused the whole save if any single reference could
  not be read, so V2 would not embed a stock LMMS demo project. **Changed later the same day, see
  ADR-0002:** it now embeds what it can and leaves the rest pointing at their paths

The all-element test, at last

Built a project carrying one of every embeddable element, each pointed at a wave of a different
length so a payload landing in the wrong attribute cannot pass silently. A total count would have
missed the sampleclip bug entirely; frame counts cannot.

    audiofileprocessor   4410, plus five of the demo's own samples
    slicert              4410
    sampleclip           8820
    tripleoscillator     13230, 17640, 22050
    elvol elcut elres    26460, 30869, 35280   (twice each, cloned track)
    lfocontroller        39690
    references still on disk: 0

Then deleted every source wave and rendered from `/`: 4066144 frames, peak 27466, mean 2985. The
same project rendered from files gives the same three numbers.

A file written by this build opens in stock LMMS 1.3

- Rendered one with stock LMMS 1.3 at the same upstream commit, every source file deleted: opens,
  reports nothing missing, 4066144 frames at peak 32767. Same as our build, mean differs by half a
  percent
- Only the SHAPE of a custom oscillator or LFO wave fails to travel, because `userwavedata` is a new
  attribute stock does not read. Every actual sample travels: `sampledata`, `data` and `sample_rate`
  are LMMS's own

BIG ONE: embedding a project with a missing sample segfaulted

- Found by testing the FAILURE path, not the success path. Everything above passed while this sat
  underneath it
- The route there is not obvious. `fromFile` returns `emptyBuffer()` when it cannot read a file,
  `emptyBuffer()` default constructs a SampleBuffer, and the class has

        sample_rate_t m_sampleRate = Engine::audioEngine()->outputSampleRate();

  as a default member initialiser. So constructing one without an audio engine dereferences null
- It only ever fires on the failure path, which is where a crash is least welcome and least likely
  to be noticed. In the GUI there is an engine so it never shows
- Fixed by checking the file exists before handing it over, which also means the error now names
  the missing sample instead of the library that gave up
- Left the upstream initialiser alone. It is a real trap for anything building a SampleBuffer
  outside a session, but that class is used all through playback and it deserves its own change
- ⚠️ so the earlier claim that embedding "refuses the whole save" on a bad reference was wrong. It
  crashed. Refusing is what it does NOW

## 08-11-2026

Building the embedder into LMMS itself

- Built LMMS from source on macOS arm64. Two things blocked it. `new (m_mapping) Header(size)`
  needs parenthesized aggregate initialization (P0960) which Apple Clang 15 does not implement,
  fixed with braces. Then `lexicographical_compare_three_way` is missing from the Command Line
  Tools libc++, so the build needs Homebrew LLVM with an explicit `-isysroot`
- ⚠️ clone the repo, do NOT download the ZIP. CMake runs a submodule check that shells out to git
  and dies immediately on an extracted archive with no `.git`
- Ran the 8 unit tests BEFORE touching anything, to have a baseline. All passed, and still pass
  after every change since

The feature

- Went in as a second checkbox in the Save As dialog, next to Save As Project Bundle. The original
  plan was a File menu entry, which was wrong: bundling is not a menu entry either, it is a
  `LedCheckBox` bound to `Song::SaveOptions`. Putting embedding anywhere else would have split two
  versions of the same idea across two parts of the UI
- The bool threaded down to `DataFile::writeFile` became a `SaveMode` enum, because there are three
  ways to save now and two bools would mean deciding what two trues mean at every call site
- `Song.h` only forward-declares `DataFile`, so a nested enum in the signature does not compile.
  Needs the actual include

The bugs that mattered, all found by testing the output rather than reading the code

- BIG ONE: **sampleclip does not use `sampledata`.** It reads `data` and writes `sample_rate`
  beside it. The first version wrote `sampledata` for every element and then removed `src`, so on a
  Sample track the payload landed where the loader never looks and the path it needed was already
  gone. The audio was just lost, no error. Every Drumline project is Sample tracks, so this would
  have hit the real work
- **Embedded audio carries no sample rate.** `fromBase64` assumes the engine rate, `fromFile` hands
  back the file's own rate. A 48kHz sample embedded raw plays a 220Hz tone at 202Hz. Same failure
  already documented in the standalone tool, and worth writing down twice because nothing anywhere
  errors. The project opens, the waveform is visible, the sample plays, and it is in the wrong key
- **libsamplerate never flushes.** `AudioResampler` always passes `end_of_input = 0`, so the last
  frames stay in the filter delay. Measured 88056 frames where 88200 were expected, so every
  embedded sample lost about 3ms off the end. Inaudible on a drum one-shot, which is exactly why it
  would have shipped. Fixed by padding the input with silence and cutting the output back
- **The save options reset after every save.** Fine for bundling, because writing a bundle twice by
  accident refuses loudly. For embedding it meant the checkbox turned itself off after one save, so
  the next save quietly wrote the project back out with file paths in it. Saving twice undid the
  first save

How that last one showed up, worth remembering

- Test file opened with "Sample not found: usergig:LOFI KICK.wav" and looked like embedding was
  broken. It was not. The 18:58 save had embedded correctly, 125KB with real audio at peak 0.99 and
  no `src` at all. The 19:00 save wrote a 3KB file with paths over the top of it, and the good
  version got pushed into the `.bak`
- The proof it was not a missing-files problem: when LMMS cannot find a sample on load it never
  calls `setAudioFile`, so `m_sample` stays empty and the next save writes `src=""`. The 19:00 file
  had real paths in it, which means the samples were present and the save simply did not embed

Going wider, because two elements is not the whole story

- `ELEMENTS_WITH_RESOURCES` lists exactly two elements. The real set of things a song can reference
  is much bigger: `tripleoscillator` userwavefile0/1/2, `elvol`/`elcut`/`elres` (three per
  instrument, on every instrument), `lfocontroller`, and `slicert` which was simply missing
- Only three elements in all of LMMS could carry embedded audio at all. The user wave ones had no
  base64 path anywhere, they only ever called `fromFile`. Added a `userwavedata` attribute to all
  of them, written only when the wave did not come from a file so the common case gains nothing
- Soundfonts, gig banks and patches stay out. Those are instrument libraries installed on a
  machine, not audio belonging to the song. Embedding them would be like shipping a copy of every
  stock plugin with the project
- ⚠️ `userwavedata` is new, so stock LMMS ignores it. **CORRECTED 08-12: I wrote here that projects
  with embedded user waves "only fully work in this build". That was wrong and I never tested it.**
  Measured against stock LMMS 1.3 at the same upstream commit, sources deleted: it opens, reports
  nothing missing, 4066144 frames at peak 32767, identical to our build. Only the SHAPE of a custom
  oscillator or LFO wave is skipped. Every actual sample travels, because `sampledata`, `data` and
  `sample_rate` are LMMS's own attributes

Packaging

- `cpack` does all the real work and then fails at the very end looking for `dmgbuild`. That
  failure is expected and harmless, the app is finished and signed before that step runs
- ⚠️ building with Homebrew LLVM means the bundle carries LLVM's libc++, which finds `libunwind`
  through `@loader_path/../unwind`. Correct in Homebrew's layout, wrong the moment macdeployqt
  moves libc++ into Frameworks. **The app does not launch at all until libunwind and libc++abi are
  both bundled.** Miss either one and the error names only the one it looked for first
- The bundle was also not self-contained on the first pass. `/opt/homebrew` sits ahead of it in the
  library search order, so it quietly loaded `libsamplerate` from Homebrew and would have failed on
  anyone else's Mac. Dropping those rpaths fixed it
- JACK is the deliberate exception, LMMS dlopens it through weakjack so a machine without it runs
  fine and just does not offer that backend
- Turning those fixes into `package-app.sh` dropped `libc++abi`, which had been copied by hand, and
  the next packaged app would not start. Lesson: when hand steps become a script, diff the script
  against what was actually done

Housekeeping

- ⚠️ an apostrophe in a path is a syntax error inside `${VAR:-default}` even in double quotes.
  Broke the packaging script on a drive named after somebody
- Had a personal external drive path baked into a public repo as a default. Fixed to `/Applications`
  with `LMMS_EMBED_DEST` for anything else. The old commit still has it in history
