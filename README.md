# lmms-embed-samples

A patch for LMMS that adds a "Save with embedded samples" option, so a project carries its own audio
and plays on a machine that doesn't have the sample files.

Against LMMS `master` (1.3.0-alpha) at commit `067c3ad4`.

## The problem

An LMMS project stores a file PATH for each sample. Send the project to someone else and LMMS finds
nothing at that path, so you get instruments that load empty and make no sound.

LMMS already ships one answer to this, the project bundle, which copies every sample into a
`resources` folder next to the project and rewrites the paths to `local:`. That works, but it gives
you a FOLDER rather than a file, it needs 1.3.0-alpha or later, and the folder has to stay intact.
Zip it wrong or move the project out of it and you're back where you started.

Embedding writes the audio into the project itself. There's no path left to break, nothing to keep
next to anything, and the result is still a single `.mmpz` you can hand to someone.

## What it adds

A second checkbox in the Save As dialog, next to the existing bundle one:

    Discard MIDI connections
    Save As Project Bundle (with resources)
    Save with embedded samples (one file, no resources)

Tick it and every sample gets written into the file as base64. Tick both and bundling wins, because
it's the older option and it leaves the samples on disk as editable files.

## What actually gets embedded

More than LMMS's own resource map covers. `ELEMENTS_WITH_RESOURCES` lists two elements, which is far
short of what a song can reference:

    audiofileprocessor   src              -> sampledata      converted to engine rate
    slicert              src              -> sampledata      converted to engine rate
    sampleclip           src              -> data            keeps its own sample_rate
    tripleoscillator     userwavefile0/1/2 -> userwavedata0/1/2
    elvol elcut elres    userwavefile     -> userwavedata    three per instrument
    lfocontroller        userwavefile     -> userwavedata

The payload attribute differs per element and getting it wrong loses the audio without a word: the
base64 lands where the loader never looks, and the path it needed has already been removed.

Only three of those could carry embedded audio at all before this patch. The user wave ones had no
base64 path anywhere — they only ever called `fromFile` — so `userwavedata` is new. **Stock LMMS
ignores it** and gives an empty slot with no warning, so projects with embedded user waves only
fully work in this build. `audiofileprocessor` and `sampleclip` embedding stays portable to stock
1.3.

Soundfonts, gig banks and patches are left out on purpose. Those are instrument libraries installed
on a machine rather than audio belonging to the song, so embedding them would be like shipping a
copy of every stock plugin with the project. VST paths are not audio at all.

## Command line

    lmms embedsamples <in> <out>

Same writer the checkbox uses. Useful for a folder of projects, and it is how the feature is
actually tested — driving a GUI to verify a file format is a bad way to spend an afternoon.

Adding it found a segfault the GUI could never expose: `embedResources()` reads the engine sample
rate, and CLI commands never start an audio engine, so the pointer is null.

⚠️ **Embedding refuses the whole save if any single reference cannot be read**, and names the one
that failed. LMMS's own DirtyLove demo trips this, because three TripleOscillator slots point at a
`samples/empty.wav` that does not resolve.

## How it fits

The save path already threaded a bool down from the dialog to the writer:

    Song::saveProjectFile(filename, withResources)
      -> DataFile::writeFile(filename, withResources)
         -> DataFile::copyResources(resourcesDir)

`copyResources()` walks a map of elements that reference files, resolves each path, copies the file
and rewrites the attribute. Embedding is the same walk with a different action, so `embedResources()`
sits next to it. There are three ways to save now, so the bool becomes a `SaveMode` enum.

## Three things this gets right that are easy to get wrong

Measured, not assumed. All of these were caught by testing the output, not by reading the code.

**sampleclip does not store audio the way audiofileprocessor does.** It reads `data`, not
`sampledata`, and writes `sample_rate` beside it. Writing the wrong attribute and then removing
`src` loses a Sample track's audio outright, with no error at any point.

**Embedded audio carries no sample rate.** `SampleBuffer::fromBase64` assumes the frames already
match the engine rate — it says so in the default argument:

    static std::shared_ptr<const SampleBuffer> fromBase64(
        const QString& str, int sampleRate = Engine::audioEngine()->outputSampleRate());

But `fromFile` hands back the file's OWN rate, because `SampleDecoder::decode` returns
`sfInfo.samplerate`. So a 48 kHz sample embedded as-is plays flat by 48000/44100. A 220 Hz tone comes
out at 202 Hz. `embedResources()` converts to the engine rate through `AudioResampler` first.

**libsamplerate never flushes.** `AudioResampler` always passes `end_of_input = 0`, so the last
frames stay stuck in the filter delay and the end of every sample gets quietly truncated. Measured at
144 frames, about 3 ms, for a 48 kHz source at SincBest. The input gets padded with silence to push
the tail through and the output is cut back to the expected length.

Neither one throws an error. You get a file that looks completely fine and is wrong, which is the
worst kind.

## Two smaller decisions

**`src` is removed, not blanked.** It's read BEFORE `sampledata` when loading, so leaving an empty
`src` behind means LMMS ignores the audio you just embedded and reports a missing file.

**`factorysample:` references are left alone.** Those ship with LMMS and resolve on any install, so
embedding them only makes the file bigger for nothing.

## Applying it

    git clone https://github.com/LMMS/lmms.git
    cd lmms
    git checkout 067c3ad4
    git am /path/to/patches/*.patch

Or take the branch directly from the fork:

    git remote add fruscai https://github.com/fruscai/lmms.git
    git fetch fruscai embed-samples
    git checkout embed-samples

`0001` is a build fix, not part of the feature. `Header` is an aggregate and placement-new with
parentheses relies on parenthesized aggregate initialization (P0960), which Apple Clang 15 doesn't
implement. Skip it if your compiler is fine with it.

## Building on macOS

The stock Command Line Tools libc++ is missing `lexicographical_compare_three_way`, which LMMS master
uses, so the build needs a newer standard library:

    brew install llvm

Then point CMake at it with `-nostdinc++ -isystem $(brew --prefix llvm)/include/c++/v1` and an
`-isysroot $(xcrun --show-sdk-path)`.

Also: clone the repo, don't download the ZIP. CMake runs a submodule check that shells out to git and
fails immediately on an extracted archive with no `.git`.

## Packaging

`package-app.sh` builds the `.app` and installs it under its own name and bundle identifier, so it
sits alongside an existing LMMS instead of fighting with it over the `.mmpz` association. Name,
identifier and destination come from `LMMS_EMBED_NAME`, `LMMS_EMBED_ID` and `LMMS_EMBED_DEST`, so
the same script builds each branch side by side without one replacing the other.

It leans on `cpack`, which does all the real work and then fails at the very end looking for
`dmgbuild`. That failure is expected and harmless — the app is finished and signed before that step
runs, and this only wants the app.

The rest of the script fixes what `macdeployqt` leaves broken when LMMS is built with Homebrew LLVM
rather than Apple Clang, and it is not optional:

- `libc++.1.dylib` finds `libunwind` through `@loader_path/../unwind`, which is correct in Homebrew's
  layout and wrong the moment `macdeployqt` moves libc++ into `Frameworks`. **The app will not launch
  at all until `libunwind` and `libc++abi` are both bundled.** Miss either one and the error names
  only the one it happened to look for first.
- `/opt/homebrew` sits ahead of the bundle in the library search order, so the app quietly loads
  `libsamplerate` and friends from Homebrew. It runs fine on the build machine and fails on anyone
  else's. Dropping those rpaths makes it actually self-contained.

JACK is the one deliberate exception. LMMS `dlopen`s it through weakjack, so a machine without JACK
runs fine and simply doesn't offer that audio backend.

The result is ad-hoc signed, not notarized. On another Mac it needs right-click then Open once.

## Verifying it worked

Decode the base64 straight out of the saved file rather than trusting a render, and point every
reference at a wave of a DIFFERENT length. Then a payload landing in the wrong attribute cannot pass
silently — which is exactly how the `sampleclip` bug hid, and a total count would have missed it.

On a project carrying one of every embeddable element:

    element              payloads  frames -> source
    audiofileprocessor   6         4410, plus five of the demo's own samples
    slicert              1         4410
    sampleclip           1         8820
    tripleoscillator     3         13230, 17640, 22050
    elvol elcut elres    6         26460, 30869, 35280   (twice each)
    lfocontroller        1         39690
    references still on disk: 0

Then delete every source wave and render from `/`:

    4066144 frames, peak 27466, mean 2985

Identical to the same project rendered from files. Not "sounds fine", identical.

Separately, for the sample rate: a 2.000 s 220 Hz tone at 48 kHz embeds to 88200 frames and measures
219.86 Hz. Without the conversion it would read 202 Hz.

## Notes

[`LOG.md`](LOG.md) has what was hit building this and why, dated.
[`DECISIONS.md`](DECISIONS.md) has the reasoning behind the choices.
[`WHERE-WE-LEFT-OFF.md`](WHERE-WE-LEFT-OFF.md) is the current state and what is still open.

## Related

[lmms-path-relinker](https://github.com/fruscai/lmms-path-relinker) does the same embedding from
outside LMMS, as standalone HTML tools, plus bulk path relinking across a whole folder of projects.
That one also handles LMMS 1.2, which this patch deliberately doesn't — see its `DECISIONS.md` for
the 1.2 versus 1.3 tree.

## License

GPLv2 or later, same as LMMS, since this is a derivative work.
