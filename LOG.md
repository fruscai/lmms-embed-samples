# Daily Log

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
- ⚠️ `userwavedata` is new, so stock LMMS ignores it and gives an empty slot with no warning.
  Projects with embedded user waves only fully work in this build. `audiofileprocessor` and
  `sampleclip` embedding stays portable to stock 1.3

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
