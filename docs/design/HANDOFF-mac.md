# Lo-Fi & Bossa: Mac design handoff

> Part of the multiplatform handoff. For iPad, iPhone and iPhone Duo see `HANDOFF.md`. File paths below are relative to `docs/design/`: the Swift files are under `starter/`, the artboards under `artboards/`.

A native macOS 14+ app (SwiftUI) that writes a short four-track song with a local model, then lets a non-musician mix it, rewrite single parts, edit notes, and export. This document is the contract between the design and the build. It covers what is decided, what is proposed, and what is still open.

The visual design lives on the Design canvas this package was exported from (23 artboards plus the icon). The `artboards/` folder holds the artboard sources. Everything that can be a number is in `tokens.json` and in the Asset Catalog.

## 1. What is in this package

| Path | What it is |
|---|---|
| `HANDOFF.md` | This document |
| `tokens.json` | Colors (light and dark), spacing, radii, sizes, type, motion |
| `icon/icon.svg` | Icon master (vector) |
| `icon/AppIcon-1024.png`, `icon/png/` | PNG renders, 16 to 1024 |
| `icon/AppIcon.appiconset/` | Drop-in Xcode icon set (all macOS sizes) |
| `icon/AppIcon.icns` | Ready-made `.icns` |
| `starter/LoFiBossa/Assets.xcassets/` | 26 color sets with light and dark values, plus `AppIcon` |
| `starter/LoFiBossa/DesignSystem/Tokens.swift` | Color, spacing, radius, size and font constants |
| `starter/LoFiBossa/Models/Models.swift` | Project, version, track, note, mix data model |
| `starter/LoFiBossa/Services/GeneratorClient.swift` | Protocol for the local generator, status and phase enums |
| `starter/LoFiBossa/Services/ProjectStore.swift` | Debounced autosave store |
| `starter/LoFiBossa/Views/TrackRowView.swift` | The track row in all states |
| `starter/LoFiBossa/Views/NoteLaneView.swift` | Miniature piano-roll overview (Canvas) |
| `starter/LoFiBossa/Views/EffectCard.swift` | Warmth / Reverb / Vinyl control |
| `starter/LoFiBossa/App/LoFiBossaApp.swift` | App shell, menu commands, split view with inspector |
| `artboards/` | Artboard sources (`.dc.html`) and `lfb.css` (the shared styles), for measurements |

**Status of the Swift files.** They were written without a compiler available, so treat them as a starting point that has not been built. Expect to fix small API details. The shell (`ProjectView`, library, inspector contents, piano roll, transport) is intentionally left as stubs that point at the artboard to build from. The pieces that carry real design decisions (track row, note lane, effect card, tokens, models, autosave) are written out.

**About `artboards/`.** The `.dc.html` files render only inside the Design canvas runtime, so they are references to read, not pages to open locally. Use the canvas for visuals. Use the files for exact values: `lfb.css` holds every measurement as a CSS rule. To get PNGs of the screens, export from the canvas (Share, then Export).

## 2. Structure decisions

**Single window with a library sidebar, not a document-based app.** The user thinks in "my tracks", not files. A single window gives autosave without save dialogs, one shared generator queue, and a library with search, rename, duplicate and Recently Deleted. The trade-off is that projects are not loose files in Finder. Sharing is through Export and "Copy Seed". If file-level sharing is wanted later, add a project-package export (a folder with `project.json`) without changing the structure.

**Three zones.** Sidebar (projects), stage (recipe bar, ruler, four tracks, transport), inspector (Sound tab and Versions tab). The piano roll is not a fourth zone: it opens as a split pane at the bottom of the stage.

**Time is in seconds.** The ruler ticks and the lane gridlines come from one list of tick positions, and every note is placed through one `x(for: seconds)` mapping. A bar/beat grid later means changing that mapping and the tick list, not the layout.

## 3. Screens and states

Artboard names are the titles on the canvas. All measurements are in points; light and dark use the same layout.

### 3.1 Project library (light and dark) and First launch

- Sidebar 216 wide: All Projects (with count), Recently Deleted, "Recent" list (six latest), New Project button pinned to the bottom.
- Toolbar: title and "N projects · saved automatically on this Mac", sort menu (Last edited, Name, Created), search field (210 wide), New Project (primary, `⌘N`).
- Content: `LazyVGrid`, four columns at 1280 wide (use adaptive columns, minimum about 220). Each card is a 12 pt radius surface: a 112 pt thumbnail of the four note lanes in the track colors, then name (rounded headline) and "Style · length · last edited".
- Context menu on a card: Open `↩`, Rename, Duplicate `⌘D`, Export… `⌘E`, Copy Seed, Delete `⌘⌫`. Double-click or Return opens. Rename is inline on the card title.
- Delete moves to Recently Deleted (30 days), then really deletes. No confirmation dialog for the move; confirm only for "Delete Permanently".
- **First launch (no projects):** the sidebar says "Projects you make will be listed here." The content is a welcome: four-bar mark in the track colors, "Make your first track", one sentence, two style cards (Lo-Fi selected, Bossa Nova), a length slider, one primary Generate button, and the generator status. Generating from here creates the first project and moves to the project view. The generator status is shown here so that an offline generator is visible before the first click.

### 3.2 Project view: loaded song

- **Toolbar:** sidebar toggle, project name (rounded 14 semibold) with subtitle "Style · length · Version N · Saved", Undo, Redo, Export (`⌘E`), inspector toggle. Rename by clicking the name.
- **Recipe bar** (49 high): Style (segmented), Length (slider 15–180 s, value shown as m:ss), Seed field, Model popup, Generate button. Generate reads "Generate" in an empty project and "Generate new take" afterwards. `⌘↩`.
- **Seed field:** a dice toggle, the number, a copy button. Dice on means a fresh random seed on every Generate, and the field shows the last seed used (or "Random" in an empty project). Typing or pasting a number turns the dice off and pins that seed. Copy copies the current song's seed. The same seed with the same style, length and model reproduces the same song.
- **Model popup:** Pretrained / Fine-tuned. Fine-tuned is listed only for styles that have it, and a disabled row says "Not available for Bossa Nova yet" otherwise. This is a testing control, so it is the first thing hidden when the window is narrow (see 3.8).
- **Ruler** (24 high) in seconds, label every 15 s at this length. Choose the label step from the length so labels never overlap.
- **Four track rows**, always in the order piano, guitar, bass, drums (section 4 is the row spec). Rows share the available height equally, with a 92 pt minimum.
- **Playhead:** a 2 pt line with a small triangle in the ruler. Click a lane or the ruler to seek.
- **Loop range:** drag in the ruler to select. The range shows as an accent wash with a label ("Loop · 22 s"), and a chip in the transport shows "0:30 – 0:52" with a clear button. The loop button in the transport toggles looping of that range. The same range is offered in the Export sheet.
- **Transport** (56 high): left, generator status; center, back-to-start, play/pause (36 pt circle), loop, time "0:36 / 1:30" (rounded 20, monospaced digits); right, range chip and master volume. Space plays and pauses.
- **Inspector, Sound tab:** three Effect cards (Warmth, Reverb, Vinyl), a "Lo-Fi defaults, adjusted" line with Reset, and a footnote. Each style applies its own default instruments and effect amounts when generated; Reset returns the effects to the current style's defaults.

### 3.3 Piano-roll editing

- **Split pane, not a separate mode.** Double-click a lane, or select a track and press Return, to open the editor for that track. The four rows collapse to 44 pt strips (name, M/S, notes only; instrument, rewrite and volume are hidden), and the editor takes the freed height. The sidebar and inspector hide while editing to give the roll its width.
- **Editor header:** track tile and name, Select / Draw tool, Snap popup (0.25 s default), "Show other parts" toggle, selection count, Loudness slider for the selection, Delete, Done.
- **Roll:** 56 pt piano-key column, 12 pt rows, 20 pt ruler, notes in the track color. The visible window in the design is 24 s; scroll horizontally and zoom with pinch. The loop range is carried over from the main view.
- **Context:** the other three tracks stay audible (playback is unchanged) and, with "Show other parts" on, are drawn as faint ghost notes in their own colors behind the editable notes. The strips above show all four tracks as usual and keep their M/S buttons.
- **Gestures:** click selects; shift-click adds; drag on empty space draws a marquee; drag a note moves it (pitch and time, snapped); drag a note's right edge resizes; double-click empty space, or Draw tool plus click, adds a note; Delete removes selected notes. The Loudness lane below the roll shows one stem per note; drag a stem to change that note's velocity.
- **Proposed shortcuts** (not in the design, easy to change): V Select, P Draw, ⌘A select all, arrows nudge by the snap value, ⌥-arrows transpose by a semitone.
- Each editing session adds one version ("Edited piano notes") when the user presses Done or leaves the track, not one per drag.

### 3.4 Generation in progress and Regenerating one track

- **Whole song:** the Generate button becomes "Generating…" with a spinner and is disabled. A banner appears under the recipe bar: spinner, "Writing a new take", "Lo-Fi · 1:30 · seed 90412 — 21 s so far, usually under a minute. Cancelling keeps your current take.", Cancel, and an indeterminate progress bar. Behind it a write head (accent line with a soft trail) moves across the lanes while notes appear behind it. The elapsed time is real; do not invent a percentage. If the generator cannot stream notes, show the lanes empty with the sweep used for single-track rewrites.
- Undo, Export and the per-track rewrite buttons are disabled while generating; playback of the previous take can continue until the new one lands, then switches. The new take is added as a new version when it finishes, and never replaces anything.
- **One track:** only that row changes. Its notes fade to 20%, a track-colored band sweeps across the lane, and a pill says "Rewriting the bass to fit the other three…" with Stop. The row's rewrite button becomes a Stop button. The other three rows stay fully usable and audible. A rewrite takes 3–5 s, so no banner is shown.
- **Reduce Motion:** replace the sweep and the write-head pulse with a static tint.

### 3.5 Generator offline, starting, error

- **Status pill** in the transport (always visible): green dot "Generator ready", spinner "Generator starting…", warning "Generator offline".
- **Starting** (usually a few seconds after launch): banner "Starting the generator. This takes a few seconds after launch. Everything except writing new music is ready." The Generate button reads "Waiting for generator…" and is disabled. It enables on its own when the status becomes ready.
- **Offline:** banner "The generator is offline. You can still play, mix, edit and export. Writing new music needs it running." with **Restart generator** (primary) and **Show log**. Restart sets the status to starting; if the process fails twice, the banner adds the last line of the log and a Copy Log button.
- **Error during generation:** banner "That take didn't finish. The generator stopped responding after 42 s. Your song is unchanged." with **Try again** (primary) and **Details**. The previous take is untouched and remains the current version. For a single-track rewrite, the same message appears as a pill on that row instead of a banner.
- All three banners are dismissible only by resolving the state; the offline banner returns until the generator is back.

### 3.6 Empty project

A new project shows "Untitled Track 3 · Lo-Fi · not generated yet". Four empty rows with their names and hatched lanes, a centered card: "Nothing written yet", one sentence, a Generate button. Undo, Export and rewrite buttons are disabled, and the seed field shows "Random". Autosave still creates the project on disk so it appears in the library.

### 3.7 A track with no notes

The lane is hatched with a pill "No notes in this part" and a **Write the guitar** action that rewrites just that track against the others (same path as the rewrite button). It is not an error: a song can legitimately have, for example, no guitar, and it stays that way until the user asks.

### 3.8 Wide and minimum window

- Minimum 900 × 560. Below 1100 wide the sidebar and inspector collapse (toolbar buttons bring them back as overlays), and the Model popup leaves the recipe bar and moves into a "Generation options" menu next to the Seed field. At 560 high each row is about 92 pt: all three lines of the header still fit.
- Wide windows give the lanes the extra width. The header stays 232 wide and the inspector 272 wide, and the sidebar stays 216. Do not add columns or panels at very wide sizes; the lanes simply get longer and the time scale stays proportional.
- See the "Minimum window" artboard.

### 3.9 Version history

- **Every Generate, every track rewrite, every note-editing session and every restore creates a version.** Versions are listed newest first in the inspector's Versions tab, grouped by day.
- A row shows four small bars (one per track, lit in that track's color where it changed), a title ("Rewrote bass", "New take · seed 48213", "Edited piano notes"), "Version 7 · 14:21", a star if kept, a badge ("Current" or "Listening"), and a play button.
- **Compare by listening:** the play button on a version plays it from the current playhead position, so switching between versions keeps the same spot in the song. A banner appears: "Listening to version 4. Rewrote guitar, 14:02…" with **Back to current** and **Restore this version**. The lanes show that version's notes while it plays. Nothing changes until Restore.
- **Restore** makes a new version on top ("Restored version 4") rather than rewinding, so no history is lost and restore is itself undoable.
- **Star (keep)** protects a version from pruning. Prune unstarred versions older than 30 days or beyond the latest 200 (proposed limit; storage per version is small because the model writes notes, not audio).
- Undo and Redo in the toolbar step the current version pointer for the last rewrite, as in the prototype; the full list is the long-term safety net.

### 3.10 Export

- A sheet (440 wide) from the toolbar button or `⌘E`: **Format** (WAV, M4A, MIDI, segmented), **Range** (Whole song, Loop range), a one-line note per format. M4A is the default.
- **In progress:** the sheet shows a determinate progress bar ("Rendering audio… 0:52 of 1:30") and Cancel. Export renders offline, faster than real time, so keep the sheet modal; no background export queue is needed.
- **Finished:** a banner "Exported. Sunday Market B-roll.m4a · 1:30 · 2.1 MB" with **Show in Finder** (primary) and Done. MIDI exports notes only, with a note saying effects and instruments are not included.
- Audio exports include the mix and effects exactly as heard.

## 4. Track row spec

Header 232 wide, three lines, 8 pt vertical and 12 pt horizontal padding, 4 pt between lines.

1. Track tile (26 × 26, 7 radius, track color at 20% with the track ink glyph), name (rounded headline), M and S keys (24 × 22, 5 radius).
2. Instrument popup (small, fills the width), then the rewrite button (or Stop when rewriting).
3. Speaker glyph, volume slider tinted in the track color, value (0–100).

Lane: surface background, notes drawn at 4 pt height, one Canvas. Click seeks. The playhead and loop range are drawn once over all rows, not per row.

| State | Rule |
|---|---|
| Normal | Full color. |
| Selected | Editor open on this track: header tint 14% and lane tint 6% in the track color. |
| Muted | M filled with the text color, notes grey at 45%, name and tile at 55%. |
| Soloed | S filled with the accent. |
| Silenced by another solo | Whole row at about 55%, notes 30%; controls stay live so the user can fix it. |
| Rewriting | Notes 20%, sweep band, pill with Stop; rewrite button becomes Stop. |
| Empty | Hatched lane, pill with "Write the …". |

Color is never the only cue: each track also has its own icon, its name, and a fixed position in the list.

## 5. Design system summary

Full values in `tokens.json`; the canvas has the visual sheet.

- **Accent:** Dendê vermilion `#C4441A` (light) and `#FF8D61` (dark). It marks the primary action, the playhead area wash, the solo key and toggled buttons. Used sparingly.
- **Track colors:** Piano indigo, Guitar honey, Bass orchid, Drums sea green. They differ in lightness as well as hue, so they stay distinguishable for the common color-blind types. Use the `…Ink` variants for text and glyphs to keep 4.5:1 contrast.
- **Neutrals:** warm paper and espresso. Light window `#F5F2EC`, dark window `#1D1A17`. Hairlines are warm alpha colors, not grey.
- **Type:** SF Pro for text, SF Pro Rounded for titles, project names, effect names and timecodes (`.fontDesign(.rounded)`). Sizes 26 / 17 / 14 / 13 / 11.
- **Spacing:** 4, 8, 12, 16, 24. **Radii:** 5 keys, 7 buttons, 8 segmented, 10 banners, 12 cards and sheets, capsule for pills and chips.
- **Controls:** native `Picker`, `Slider`, segmented control, `Menu`, `Toggle`. The only styled controls are the M/S keys, the Effect cards, the seed field and the pills.
- **Icons:** SF Symbols (list on the "Design system" artboard). The canvas draws stand-in glyphs; use the named symbols in the build. Drums needs a custom symbol (no suitable system symbol exists).
- **Motion:** sweep 1.8 s, write-head pulse 1.2 s, spinner 0.8 s, all disabled or made static under Reduce Motion.

## 6. SwiftUI implementation notes

**Standard controls and containers**

- `NavigationSplitView` (sidebar) and `.inspector(isPresented:)` (right panel, macOS 14).
- `.toolbar` with `ToolbarItem` groups; `.searchable` for library search; `LazyVGrid` with `.contextMenu` and inline rename (`@FocusState` + `TextField`).
- `Picker` (`.segmented` and `.menu` styles), `Slider`, `Menu`, `Toggle(.button)` for Snap and "Show other parts".
- `.sheet` for Export with `ProgressView(value:)`; `.fileExporter` or an `NSSavePanel` wrapper for the final write; `NSWorkspace.activateFileViewerSelecting` for Show in Finder.
- `UndoManager` through the environment for Undo/Redo; menu commands via `.commands` (see `LoFiBossaApp.swift`).
- `.fontDesign(.rounded)`, `monospacedDigit()`, SF Symbols, `ContentUnavailableView` for empty states.

**Custom drawing and interaction**

- **Note lanes and library thumbnails:** one `Canvas` each (`NoteLaneView`). Cheap enough for 4 lanes of a few hundred notes.
- **Ruler, playhead, loop range:** a single overlay across the rows with a `DragGesture` for range selection and `SpatialTapGesture` for seek. Drive the playhead from the audio engine's clock with `TimelineView(.animation)`, not from a `@State` timer.
- **Piano roll:** `Canvas` plus gestures for select, move, resize and marquee. Hit-test against the model, not views. If scrolling and zooming 24 s windows with a few hundred notes ever stutters, move this one surface to an `NSViewRepresentable` backed by a layer-based `NSView`. This is the only piece where that is likely to be needed.
- **Effect cards:** custom drag surface with an accessibility adjustable action (`EffectCard.swift`).
- **M/S keys, seed field, pills, status pill:** small `ButtonStyle`s and views.
- **Sweep and write head:** `TimelineView(.animation)` with `GeometryReader`; both must honor `accessibilityReduceMotion`.

**Audio**

- The model writes notes; the app plays them with sampled instruments (`AVAudioUnitSampler` per track, or a sampler bank) through an `AVAudioEngine` graph: four tracks, per-track volume and mute/solo, then master Warmth (low-pass `AVAudioUnitEQ` or a custom filter), Reverb (`AVAudioUnitReverb`) and Vinyl (a noise and crackle source mixed in). Export renders the same graph offline with `enableManualRenderingMode`. MIDI export writes the notes only (`MusicSequence` or a small SMF writer).
- Looping and range export both take `ClosedRange<Double>` in seconds.

**State**

- One `@Observable` view model per open project holding: current snapshot, generation phase, generator status, playhead, loop range, selected track, selected notes, listening-version id. Mutations go through methods that also create versions and call `ProjectStore.update`.
- Rewrites and generations run as cancellable `Task`s; Cancel and Stop cancel the task and the request to the process. A rewrite must send the other three tracks so the model can fit the part to them.

**Accessibility**

- Every icon-only button has a label. M and S announce on/off. Effect cards are adjustable. The track row is a `contain` group named "Piano track". Status changes (generator ready/offline, generation finished or failed) post an accessibility announcement.
- Piano-roll notes need a keyboard path: select with arrows, nudge with modifier arrows, delete with Delete. Budget time for this; it is the largest accessibility item.

## 7. Suggested build order

1. Tokens and Asset Catalog (done in this package), app icon.
2. Models and `ProjectStore` with autosave; library with create, rename, duplicate, delete, search.
3. Project view with static data: recipe bar, four `TrackRowView`s, ruler, transport, inspector Sound tab.
4. Audio engine playback, mute/solo/volume, seek, loop, effects.
5. `GeneratorClient` against the local process; status pill and banners; generate with cancel; per-track rewrite.
6. Versions (create, list, listen, restore, keep).
7. Piano-roll editor.
8. Export (WAV, M4A, MIDI) with range.
9. First launch and polish: Reduce Motion, VoiceOver pass, keyboard shortcuts.

## 8. Assumptions and open questions

- **Streaming notes.** The write-head animation assumes the model can stream notes while it writes. If it only returns a finished song, use the sweep and the elapsed-time banner. Please confirm with the generator work.
- **Seed meaning for rewrites.** A rewrite seed is derived from the song seed plus the track, so "same seed, same song" still holds for generations only. Rewrites are reproduced from the saved version, not from the seed.
- **Version for note edits.** The design adds a version per editing session ("Edited piano notes"). If versions should be generations only, drop this kind and let note edits live on the current version.
- **Version limits** (30 days, 200 versions) are proposals.
- **Instrument names** per track are placeholders; replace with the real sampler bank.
- **Project names** and sample numbers in the artboards are illustrative content. "Dendê" and the style captions are copy suggestions and can change.
- **Icon:** delivered as a classic `AppIcon.appiconset` and `.icns`. For macOS 26 and later you can also build a layered icon in Icon Composer using the SVG: the sun disc, the four notes and the ground are separate shapes in `icon.svg`. The 16 and 32 px renders are plain downsamples; check them in the Dock and simplify (thicker outlines, fewer vinyl rings) if the notes blur.
- **Not designed:** Preferences, onboarding for the sampler download (if any), a bar/beat grid, Recently Deleted screen (it is the library filtered to deleted items), and localization.
