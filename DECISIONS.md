# Decisions

## 08-11-2026 - Building the embedder into LMMS itself

The HTML embedder already does this from outside. This is the same thing as a native save option,
built mostly because it should be possible, and because saving straight out of LMMS beats exporting
and then running a second tool over the result.

The short version

- **It goes in the Save As dialog, not a menu.** That is where bundling already lives.
- **The bool becomes an enum.** Three ways to save now, and a second bool would have meant deciding
  what two trues mean at every call site.
- **Audio gets converted to the engine rate before it goes in.** Skipping this is the single thing
  most likely to produce a file that looks right and plays wrong.
- **This patch deliberately does NOT write `srcdata`.** That is the 1.2 workaround, and it belongs in
  the standalone tool, not here.

Why a checkbox rather than a menu item

The plan going in was a menu entry under File. Reading the code killed that idea: bundling is not a
menu entry either. It is a `LedCheckBox` in the Save As dialog bound to
`Song::SaveOptions::saveAsProjectBundle`, and `guiSaveProjectAs` reads that model when the dialog
closes. Putting embedding anywhere else would have split two versions of the same idea across two
parts of the UI. It goes next to bundling because that is where somebody already looks when they are
thinking about how a project travels.

Cost of that: it touches seven files instead of three, because the option has to exist as a
`BoolModel` on `Song::SaveOptions` and get read back out again. Worth it.

One real gotcha: `Song.h` only forward-declares `DataFile`, so putting a nested `DataFile::SaveMode`
in the `saveProjectFile` signature does not compile. It needs the actual include.

Why an enum instead of a second bool

    writeFile(filename, withResources)          -> writeFile(filename, SaveMode::Bundle)

With two bools, every call site has to answer what happens when both are true, and nothing in the
signature says which wins. With `SaveMode::Plain / Bundle / Embedded` the question can only be asked
once, in `guiSaveProjectAs`, where the answer belongs.

If both boxes are ticked, bundling wins. It is the older option and it leaves the samples on disk as
editable files, so it is the less destructive of the two.

Resample to the engine rate before embedding

Measured, not assumed. `sampledata` is a raw frame array with no sample rate stored anywhere in it,
so the loader has to assume one, and the header says out loud which one it assumes:

    static std::shared_ptr<const SampleBuffer> fromBase64(
        const QString& str, int sampleRate = Engine::audioEngine()->outputSampleRate());

`fromFile` does the opposite. It hands back whatever the file was, because `SampleDecoder::decode`
returns `sfInfo.samplerate`. So embedding a 48 kHz sample into a 44.1 kHz engine writes frames the
loader then reads too slowly, flat by 48000/44100. A 220 Hz tone comes out at 202 Hz.

This is the same failure already documented in the standalone tool, and it is worth writing down
twice because nothing anywhere errors. No warning, no missing file, no red text. The project opens,
the waveform is visible, the sample plays, and it is in the wrong key.

`AudioResampler` was already in the tree and takes interleaved float. A `SampleFrame` is two floats,
so a `std::vector<SampleFrame>` hands straight to it as an `InterleavedBufferView<const float>` with
two channels. No new dependency and no hand-written interpolation.

The resampled buffer gets constructed with NO audio file path, on purpose. Handing it one would put
back the external dependency the whole feature exists to remove.

Pad the input so libsamplerate flushes

Caught by counting frames in the output rather than listening to it. A 2.000 s source at 48 kHz
should give 88200 frames at 44.1 kHz. It gave 88056.

`AudioResampler::process` always passes `end_of_input = 0`, so libsamplerate holds the last frames
inside its filter delay and there is no second call to get them out. Every embedded sample was losing
144 frames, about 3 ms, off the end. On a drum one-shot that is the tail of the decay and nobody
would ever hear it, which is exactly why it would have shipped.

Fix is to append silence to the input, let that push the real tail through, then cut the output back
to the length it should have been. The alternative was changing `AudioResampler` to expose
`end_of_input`, which is a shared class used for sample playback, and this did not seem worth
touching it for.

Remove `src`, do not blank it

`loadSettings` reads `src` first and only falls through to `sampledata` when it is empty:

    if (auto srcFile = elem.attribute("src"); !srcFile.isEmpty())
    ...
    else if (auto sampleData = elem.attribute("sampledata"); !sampleData.isEmpty())

Leaving `src=""` in place technically works, since empty counts as empty. Removing it is still the
right call — an empty attribute sitting next to the audio invites exactly one confused bug later, and
`saveSettings` writes `src` unconditionally so it would come straight back on the next save anyway.

Skip `factorysample:`

Those ship with LMMS and resolve on any install, so embedding them makes the file bigger and buys
nothing. Everything else gets embedded, including `usersample:`, `usergig:` and plain absolute paths,
because none of those can be counted on to exist somewhere else.

Why `srcdata` is NOT written here

LMMS 1.2 checks one attribute and reads another:

    else if( _this.attribute( "sampledata" ) != "" )
    {
        m_sampleBuffer.loadFromBase64( _this.attribute( "srcdata" ) );
    }

So a file embedded the correct way passes 1.2's check, loads an empty string, and plays silence with
no error at all. The standalone tool writes the payload to both attributes to get around this,
because it cannot control which LMMS opens the file.

That is the wrong call inside LMMS itself. It doubles the file size for every 1.3 user in order to
work around a bug in a branch that is not taking fixes, and this build IS 1.3, so anything it saves
is already going to be opened by something that reads `sampledata` properly. Version mismatch between
what people author in and what a grader or collaborator runs is real and permanent, but the place to
paper over it is the external tool, not the editor.

The resource map is narrower than it looks

    { "sampleclip", {"src"} },
    { "audiofileprocessor", {"src"} },

Two elements, one attribute each. `tripleoscillator` carries `userwavefile0/1/2` and is not in the
list, which is why `makebundle` silently leaves those pointing at files that may not exist — the same
blind spot that produced a mystery `empty.wav` reference in the standalone tool's test projects.

Left alone here on purpose. Widening that map changes what bundling does too, and that is a separate
bug with its own reproducer, not something to smuggle in under a new feature.

Keep the build fix as its own commit

`0001` changes `new (m_mapping) Header(size)` to `Header{size}`. `Header` is an aggregate, and
placement-new with parentheses relies on parenthesized aggregate initialization (P0960), which Apple
Clang 15 does not implement. It has nothing to do with embedding and anyone whose compiler is fine
can drop it, so it stays separate rather than getting buried in the feature diff.
