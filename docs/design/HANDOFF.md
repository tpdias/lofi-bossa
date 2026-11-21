# Lo-Fi & Bossa: iPad, iPhone and iPhone Duo handoff

Lo-Fi & Bossa now ships on Mac, iPad, iPhone and the foldable iPhone Duo. **Every device has the same features**: generate, choose style, length, seed and model, mix, mute and solo, swap instruments, rewrite one part, edit notes, three effects, loop a range, versions with listen-and-restore, export WAV, M4A or MIDI, projects with autosave. Only the layout and the input change.

This document covers what is different on each device. `HANDOFF-mac.md` stays the reference for behaviour that is the same everywhere: states, copy, the version rules, the track-row states, and audio. Where this document is silent, the Mac behaviour applies.

The designs are on the same Design canvas as the Mac screens, in four new rows: iPhone light, iPhone dark and landscape, iPad, and iPhone Duo.

## 1. What is in this folder

| Path | What it is |
|---|---|
| `HANDOFF.md` | This document (iPad, iPhone, iPhone Duo and what they share) |
| `HANDOFF-mac.md` | The original Mac handoff: per-screen behaviour, states, design system, SwiftUI notes |
| `tokens.json` | Design tokens, now with touch and phone sizes |
| `icon/` | macOS icon (as before), plus iOS any / dark / tinted, and `layers/` for Icon Composer |
| `artboards/` | All artboard sources from the canvas (`Phone.dc.html`, `Duo.dc.html` and the iPad wrappers are new) and the shared `lfb.css` |
| `starter/LoFiBossa/` | Multiplatform SwiftUI starter: asset catalog, tokens, models, session, layout switch, Mac/iPad, iPhone and Duo views |

The Swift files have not been compiled; no Xcode was available while they were written. Treat them as a structured starting point and expect small API fixes. The artboards render only inside the Design canvas. Read them for exact values; `lfb.css` holds every measurement.

## 2. How the app adapts

### 2.1 One target, four layouts

Layout is chosen from the size class and the fold, never from the device model. That way iPad Split View, Stage Manager and the Duo all follow one rule (`starter/LoFiBossa/Platform/LayoutMode.swift`).

| Layout | When | Looks like |
|---|---|---|
| **regular** | Mac; iPad full screen or wide | The Mac layout: sidebar, stage with track rows, inspector. Touch-sized on iPad. |
| **compact** | iPhone; iPhone Duo closed; narrow iPad Split View or Slide Over | Stacked track cards, floating transport, sheets |
| **twoPage** | iPhone Duo open, fold vertical (flat or half folded like a book) | Song on the left page, panel on the right page |
| **tabletop** | iPhone Duo half folded with the fold horizontal | Watch on top (lanes), touch below (transport, effects, solo) |

### 2.2 One panel, three presentations

Sound, Versions and Notes (the piano roll) are one panel model (`Panel` in `ProjectSession.swift`), shown differently per layout:

| | Sound | Versions | Notes (piano roll) |
|---|---|---|---|
| Mac, iPad | Inspector tab | Inspector tab | Bottom split pane |
| iPhone, Duo closed | Sheet from the transport | Sheet from the transport | Pushed full-screen editor (rotates to landscape) |
| Duo open | Right page tab | Right page tab | Right page tab |

### 2.3 State survives layout changes

All state for an open project lives in one `ProjectSession` above the layout switch: playhead, loop, selection, the version being listened to, and any generation in progress. Unfolding a Duo, rotating an iPhone or resizing an iPad window therefore never stops playback or cancels a generation. Apple treats Duo fold changes as size-class and trait changes in the same process, not as a new scene, so this works without special handling.

When the layout changes, the open panel carries across:

- **Unfold (compact → twoPage):** an open Sound or Versions sheet closes, and that panel becomes the right page's tab. A pushed piano roll becomes the Notes tab.
- **Fold (twoPage → compact):** the Notes tab becomes the pushed editor. Sound and Versions go back to the transport buttons; no sheet opens by itself.

### 2.4 Feature map

Where each feature lives on each device.

| Feature | Mac / iPad | iPhone (and Duo closed) | Duo open |
|---|---|---|---|
| Style, length, seed | Recipe bar | Recipe strip chips (menus, popovers) | Recipe strip, left page |
| Model (Pretrained / Fine-tuned) | Recipe bar popup (hidden when narrow) | More menu › Generation options | More menu › Generation options |
| Generate / New take | Recipe bar, ⌘↩ | Strip button | Strip button |
| Mute, solo, rewrite | Track row | Track card | Track card |
| Instrument, volume | Track row | Track sheet (tap the name) or long press | Track sheet or long press |
| Effects | Inspector › Sound | Sound sheet | Right page › Sound |
| Versions | Inspector › Versions | Versions sheet | Right page › Versions |
| Piano roll | Bottom split pane | Pushed editor | Right page › Notes |
| Loop range | Drag in the ruler | Drag in the scrubber; long-press a lane | Drag in the scrubber |
| Export | Toolbar, ⌘E, sheet | More menu › Export…, sheet, then Share / Save to Files | Same as iPhone |
| Undo | Toolbar, ⌘Z | Nav bar button, shake-to-undo off | Nav bar button |
| Generator status | Transport pill | Banner only when not ready | Banner only when not ready |
| Projects | Sidebar + library grid | Library grid (2 columns) | Library list + preview |

## 3. Devices and sizes

All values are in points. Layouts flex; these are the sizes the artboards are drawn at.

| Device | Artboard size | Size class (w / h) | Notes |
|---|---|---|---|
| iPhone 6.3" | 402 × 874, landscape 874 × 402 | compact / regular | Portrait for the app; landscape offered in the piano roll |
| iPad 11" | 1194 × 834, portrait 834 × 1194 | regular / regular | Scales to 13" without changes |
| iPhone Duo, closed (outer) | 466 × 678 * | compact / regular | iPhone layout, short variant |
| iPhone Duo, open (inner) | 890 × 626 * landscape, 626 × 890 * portrait | regular / regular | Two pages; tabletop when half folded |

\* The Duo point sizes are third-party arithmetic from the published pixel sizes at 3x (1878 × 2670 inner, 1398 × 2034 outer). Apple's pages give the size classes but not point sizes. Confirm them in Xcode's Device Hub and read sizes at runtime rather than hard-coding them.

No status bar, Dynamic Island or home indicator is drawn in the artboards; that space is left empty, and the system draws them. The insets used are 62 pt top and 34 pt bottom on iPhone portrait, 59 pt sides and 21 pt bottom on iPhone landscape, 24 pt top on iPad, and 44 / 16 pt on the Duo's outer display. On the Duo, Apple says safe areas can be asymmetric, with vertical bars giving leading or trailing insets, so treat each edge on its own.

## 4. iPad

The iPad uses the Mac layout. The artboards are `Main.dc.html` and `Library.dc.html` with `platform="ipad"`, so any change to the Mac design flows to iPad automatically. Differences:

- **Touch sizes** (`.touch` in `lfb.css`, `LFBSize` in Swift):

  | Element | Mac | iPad |
  |---|---|---|
  | Controls | 28 | 36 |
  | M / S keys | 24 × 22 | 36 × 32 |
  | Track header width | 232 | 264 |
  | Transport height | 56 | 76 |
  | Play button | 36 | 52 |
  | Inspector width | 272 | 320 |
  | Sidebar width | 216 | 300 |
  | Slider thumbs | 16 | 24 |
  | Effect cards | 64 | 76 |

  Keyboard hints (⌘↩) are hidden on iPad. With a hardware keyboard, the same shortcuts are listed when the user holds ⌘ (they come from `.commands`).
- **No window chrome:** no traffic lights, and a 24 pt top inset for the status bar.
- **Sidebar starts hidden while a project is open** to give the lanes width; the toolbar button shows it as an overlay. The library keeps it visible. The library grid is 3 columns in landscape.
- **Portrait (834 wide):** the inspector and Model popup collapse exactly as on a narrow Mac window. The inspector toggle shows the inspector as an overlay from the trailing edge. The "iPad · Portrait · versions" artboard shows the stage with the version-listening banner.
- **Piano roll with Apple Pencil:** Pencil draws notes directly; a finger selects, moves and scrolls, so no tool switch is needed. The editor header shows "Pencil draws · finger moves" until the user has used Pencil once. Squeeze on Apple Pencil Pro toggles Select / Draw. Pointer behaviour (trackpad) is the same as on Mac, including hover.
- **Context menus** on library cards open on long press, with the same items as the Mac.
- **Export finished:** the banner offers **Share…** and **Save to Files** instead of Show in Finder.
- **Split View / Slide Over:** below regular width the app switches to the iPhone layout (`compact`). Nothing special is needed.
- **Multiple windows:** allowed. Two windows on the same project share one `ProjectSession`, and only one plays at a time (the most recent).

## 5. iPhone

The artboards are `Phone.dc.html` (one component, a `view` prop for each state) and its wrappers.

### 5.1 Library and first launch

- **Library:** large title "Projects", a sort/filter menu at the leading edge, a **+** button (new project) at the trailing edge, a search field, and a 2-column grid of cards, each with a 4-lane thumbnail, name and "style · length · last edited". Long press opens the context menu: Rename, Duplicate, Export…, Copy Seed, Delete. Swipe actions are not used in a grid.
- **First launch:** the welcome is stacked: mark, title, one sentence, the two style cards full width, the length slider, a full-width Generate button and the generator status. Generating creates the first project and pushes the project screen.

### 5.2 Project screen

From top to bottom:

1. **Navigation bar:** "‹ Projects" back button; title (rounded 16 semibold) with "Lo-Fi · 1:30 · Saved"; Undo; More (Export…, Rename, Duplicate, Copy Seed, Generation options › Model, Delete).
2. **Recipe strip:** capsule chips (36 pt high):
   - **Style:** a menu.
   - **Length:** a popover with a slider and the value.
   - **Seed:** a popover with the dice toggle, a numeric field and Copy. The chip is tinted when the dice is on.
   - **New take:** the primary button; it reads "Generate" in an empty project.

   While a song is generating, the generating banner replaces the strip.
3. **Ruler:** 0:00, 0:30, 1:00 labels, aligned with the lanes.
4. **Four track cards** fill the remaining height (see 5.3).
5. **Floating transport** (radius 26, raised, above the home indicator):
   - **Top row:** a scrubber with the playhead knob and the loop range, then elapsed time · "Loop 0:30 – 0:52" · total.
   - **Bottom row:** **Sound** (opens the sheet) · back to start · play (56 pt) · loop · **Versions** (opens the sheet).

Below about 760 pt of height (the Duo's outer display), the short variant applies (`.m-short`): smaller card padding, a 48 pt play button, transport labels hidden, and the time row folded away.

### 5.3 Track card

- **Header (40 pt):** track tile, name with the instrument underneath, then Rewrite, M and S. Each is drawn at 40 × 36 with the hit area padded to 44.
- **Lane:** the note overview, with the loop range, playhead and write head drawn in every lane.
- **Gestures:**
  - Tap the name for the track sheet.
  - Long press the card for a context menu: Instrument, Edit notes, Rewrite.
  - Tap a lane to seek; long press and drag in a lane to set the loop range.
- **States:** the same as the Mac track row: normal, selected (2.5 pt outline in the track color), muted, soloed, silenced by another solo, rewriting (sweep, pill with Stop, the rewrite key becomes Stop), and empty (hatched lane with "Write the guitar").

### 5.4 Sheets

All sheets use the system sheet with a grabber. Background interaction stays enabled up to the medium detent, so the user can keep playing and scrubbing while adjusting sound.

- **Track** (medium/large): instrument list with a checkmark, volume slider, Mute and Solo, "Edit notes ›", "Rewrite this part · about 5 s".
- **Sound** (medium): the three effect cards (76 pt, the whole card is the slider) and Reset.
- **Versions** (medium/large): the listening banner (Back to current, Restore) and the version list. Each row has its change bars, badges, and a 40 pt listen button that becomes Stop while listening. Swipe a row to Keep (star) it.
- **Export** (medium):
  - Format (WAV / M4A / MIDI) and Range (Whole song / Loop) as segmented controls, a note, then Export.
  - While exporting, a determinate progress bar with Cancel.
  - When finished, an "Exported" confirmation with **Share…** (the system share sheet, for example straight into a video editor) and **Save to Files**.

### 5.5 Piano roll

The piano roll is pushed full screen from "Edit notes".

- **Portrait:**
  - **Top bar:** Done, title "Piano · Electric Piano · 0:24 – 0:36", Select / Draw.
  - **Option chips:** Snap and "Show other parts", plus Undo.
  - **Roll:** 18 pt rows, 40 pt key column, a 12 s visible window, and ghost notes of the other parts.
  - **Loudness lane** below the roll.
  - **Action bar:** "4 selected · Loudness" slider, Duplicate, Delete, Play.
- **Landscape** (the system rotates when the user turns the phone): one top bar holds every control, and the roll shows 24 s at 12 pt rows. The app only rotates in this editor; the rest of the app stays portrait on iPhone.
- **Touch gestures:**
  - Tap a note to select it; tap empty space to deselect.
  - Drag a selected note to move it (snapped). Drag the round handle on its right edge to resize.
  - One-finger drag on empty space scrolls; pinch zooms time; two-finger vertical drag scrolls pitch.
  - Long press then drag on empty space draws a marquee.
  - With the Draw tool, tap to add a note at the snap length.
  - Drag a stem in the loudness lane to change that note's loudness.
- The other three parts keep playing. A version is added when the user taps Done (one per editing session), the same as on Mac.

### 5.6 States

The same as the Mac, adapted:

| State | iPhone |
|---|---|
| Generating | Banner replaces the strip: spinner, "Writing a new take", "21 s so far, usually under a minute. Your current take is kept.", Cancel, indeterminate bar. Write head and partial notes in the lanes. Rewrite keys disabled. |
| Rewriting one track | Only that card changes (sweep, pill, Stop). |
| Empty track | Hatched lane, "No notes", **Write the guitar**. |
| Empty project | Strip shows "Random" seed (tinted) and **Generate**; lanes empty; Undo disabled. |
| Generator starting | Banner "Loading the music model… A few seconds after launch."; Generate reads "Waiting…". |
| Generator not running | Warning banner "The generator isn't running. Play, mix, edit and export still work." with **Restart** and **Details**. |
| Error | Error banner "That take didn't finish. Your song is unchanged." with **Try again** and **Details**. |
| Export in progress, finished | Inside the Export sheet (see 5.4). |

## 6. iPhone Duo

### 6.1 Closed

The outer display is a compact-width iPhone, so the iPhone layout is used unchanged, in its short variant at 466 × 678. See "Duo closed · Project" and "Duo closed · Sound · dark".

### 6.2 Open: two pages

The inner display is regular/regular. The app splits it into two equal pages with a 24 pt gap centred on the fold. The red guides on the canvas mark the fold.

| Mode | Left page | Right page |
|---|---|---|
| Library | Large title, search, list of projects (thumbnail, name, meta) | Preview of the selected project: large 4-lane thumbnail, name, "style · length · seed · versions · edited", **Open**, preview play, Duplicate, Export |
| Project | Nav bar, recipe strip, four track cards, single-row transport (play, time, scrubber with loop range, loop) | Segmented **Sound / Versions / Notes**, then that panel |
| Generating | Banner with Cancel, write head in the lanes | Sound stays usable: "Keep playing with the sound while the new take is written." |
| Piano roll | The piano card is selected (outlined); the other parts stay visible and audible | Notes: Select / Draw, Snap, roll with 17 pt rows, loudness lane, "4 selected · Loudness", Delete, Done |
| Versions | Lanes show the version being listened to | Listening banner and version list |

**Rules for the fold:**

- Nothing interactive spans the fold. Lanes, the transport scrubber and the piano roll each stay on one page, because a drag across the fold is unreliable when the device is half folded.
- The same split is used flat and half folded like a book, so nothing jumps when the hinge moves. This follows Apple's advice not to design a bespoke layout for every way the device is held.
- When Apple's `ArrangementView` and `ReservedRegion` APIs (iOS 27.1) are adopted, they replace the fixed split and keep the gap where the system says the fold is.

### 6.3 Half folded, fold horizontal: tabletop

When the Duo is rotated and half folded so that it stands on a table:

- **Top half (watch):** title, and four full-width lanes with a name tag, loop range and playhead.
- **Bottom half (touch):** a large transport (back, 64 pt play, loop, time), three tall effect cards side by side, and a Solo button per track.

This is the "mix while it plays" posture. Generation, versions and the piano roll stay available by flattening the device, which returns to the two-page layout with state unchanged.

### 6.4 Fold and hinge APIs

Apple's developer forum names these, for the iOS 27.1 SDK. Verify the shipping signatures before use; they are written as TODOs in `LayoutMode.swift` and `DuoViews.swift`.

- **`onHingeChange` (SwiftUI) / `UIHingeInteraction` (UIKit):** hinge status and angle. Prefer the status (closed, partially open, open) over an angle threshold.
- **`ReservedRegion`:** the fold and camera areas to keep custom controls out of.
- **`ArrangementView`:** split layouts across the fold.
- **`toolbarVerticalEdge`:** vertical toolbars. Not used by this design, which keeps its toolbars horizontal.
- **Testing:** use Device Hub in Xcode 27.1 to test the Duo's positions (closed, open, half folded, tabletop).

## 7. The generator on iPhone and iPad (architecture note)

On the Mac, the model runs in a separate local background process. iOS and iPadOS do not allow an app to keep its own long-running helper process, so on these devices the model has to run **inside the app**, for example with Core ML or MLX. The UI states stay the same, but they mean different things:

| State | Mac | iPhone / iPad |
|---|---|---|
| Starting | Process launching | Loading the model into memory after launch |
| Offline ("isn't running") | Process not running | Model not loaded: failed to load, not enough memory, or not downloaded yet |
| Restart | Relaunch the process | Reload the model; if it is not on the device, offer **Download model ([MODEL SIZE])** |

- **Backgrounding:** iOS suspends apps it moves to the background. A 15–60 s generation would be lost if the user switches apps. Options to evaluate: `BGContinuedProcessingTask` (iOS 26 and later, for user-started work that should finish; verify that it fits a GPU or Neural Engine workload), or keep the take on suspension and offer "Try again" on return. The design assumes the second option as the fallback: the banner turns into the error banner, and the current take is never lost.
- **Speed, memory and heat:** timings on iPhone may differ from the Mac's 15–60 s. Replace "usually under a minute" with measured estimates per device class, and handle thermal pressure as an error state with the same copy.
- **Alternative:** iPhone and iPad could use a nearby Mac's generator instead. That is a product decision (see 11).

## 8. Audio and files on iOS

- **Audio session:** use the `.playback` category so music plays with the silent switch on. Enable the background audio mode so playback continues when the user leaves the app. Pause on interruptions (calls) and on headphone unplug.
- **Export:** write to a temporary file, then present `ShareLink` or the share sheet (Share…) or `fileExporter` (Save to Files). The audio rendering path (`AVAudioEngine` manual rendering) is the same as on Mac.
- **Projects:** stored in the app's Application Support folder, exactly as on Mac (`ProjectStore`).

## 9. Icon

- `icon/AppIcon-iOS.png`: full-bleed, opaque 1024 × 1024. The system applies the rounded mask, so the artwork is scaled up from the Mac grid.
- `icon/AppIcon-iOS-dark.png`: the sun and notes on a transparent background, for the dark Home Screen.
- `icon/AppIcon-iOS-tinted.png`: grey sun with white notes on transparent, so the notes stay legible when the system tints the icon.
- `starter/LoFiBossa/Assets.xcassets/AppIcon.appiconset`: one set holding both the Mac sizes and the iOS universal 1024 variants.
- `icon/layers/`: background, sun and notes as separate SVGs, to rebuild the icon in Icon Composer for the current layered and glass icon styles on every platform.

Check the dark and tinted variants on a device. The tinted variant follows the common convention of grayscale artwork on transparent; confirm with Xcode's preview.

## 10. Accessibility on touch

- Every touch target has at least a 44 pt hit area. M, S and Rewrite are drawn smaller, at 40 × 36, and padded.
- Track cards expose VoiceOver custom actions (Mute, Solo, Rewrite, Edit notes, Change instrument), so the card can be one element with actions rather than five stops.
- **Dynamic Type:**
  - Chips, cards and sheets grow with the text size.
  - At accessibility sizes, the instrument line under the track name moves into the track sheet, and the transport keeps only its icons.
  - The piano roll keeps its size and offers zoom instead.
- The effect cards are adjustable (swipe up or down), and the sweeps and write head respect Reduce Motion, the same as on Mac.

## 11. Assumptions and open questions

1. **Where the generator runs** on iPhone and iPad: in the app (assumed here), or on a nearby Mac. This affects download size, speed and the offline state's recovery button.
2. **Sync across devices:** with the same features everywhere, users will expect a project made on the iPhone to open on the Mac. Projects are local per device in this design. iCloud sync (CloudKit, or iCloud Drive with a project package) is recommended, and would need a small "synced / syncing / conflict" design. This is not designed yet.
3. **Duo point sizes and fold position:** unconfirmed (see 3). The design depends only on the fold being at the centre of the inner display.
4. **Duo multiple windows:** Apple allows multiple windows on the inner display. The design supports it through the regular layout but does not show it.
5. **iPhone orientation:** portrait only, except in the piano roll. Confirm this is acceptable.
6. **Model size and download flow** on iOS: the placeholder is [MODEL SIZE]. A download progress state is needed if the model is not bundled.

## 12. Swift starter: what is new

| File | Purpose |
|---|---|
| `Platform/LayoutMode.swift` | `LayoutMode`, `FoldInfo` environment value, `LayoutModeReader` (size class + fold) |
| `Models/ProjectSession.swift` | Shared, observable state above the layout switch; `Panel` and `CompactSheet` |
| `Views/Shared/PanelView.swift` | Sound, Versions, Notes panel used by every layout; piano-roll gesture spec per input |
| `Views/Phone/TrackCard.swift` | Compact track card with all states and the 44 pt touch key style |
| `Views/Phone/PhoneProjectView.swift` | iPhone project screen, recipe strip, floating transport, sheets with detents |
| `Views/Duo/DuoViews.swift` | Two-page project view and tabletop view |
| `App/LoFiBossaApp.swift` | Multiplatform app, shared commands, `AdaptiveRootView` |
| `DesignSystem/Tokens.swift` | Adds touch sizes (`LFBSize.isTouch`) and phone/Duo sizes |

**Suggested order after the Mac build order:**

1. Adopt `ProjectSession` and `LayoutModeReader` and run the Mac layout on iPad.
2. Build the iPhone project screen and the sheets.
3. Build the iPhone piano roll with touch gestures.
4. Add Pencil support on iPad.
5. Add the Duo two-page and tabletop layouts, then adopt the iOS 27.1 fold APIs.
6. Do the in-app generator work (section 7) in parallel from the start; it is the largest risk.

## Sources for the iPhone Duo facts

- [Prepare your app for iPhone Duo (Apple Tech Talk)](https://developer.apple.com/videos/play/tech-talks/111461/): size classes, adaptive navigation, safe areas, reserved regions, Device Hub.
- [Apple Developer Forums thread 847644](https://developer.apple.com/forums/thread/847644): API names (`onHingeChange`, `ReservedRegion`, `ArrangementView`), continuity on fold and unfold.
- [Apple Newsroom, October 2026](https://www.apple.com/newsroom/2026/10/developers-bring-incredible-new-app-experiences-to-iphone-duo/): fold-aware standard components, half-folded examples.
- [MacRumors: iPhone Duo](https://www.macrumors.com/roundup/iphone-duo/): display sizes and resolutions, open and closed dimensions.
- [ziplyne.agency](https://ziplyne.agency/blog/iphone-duo-for-developers-screen-sizes-layout-rules-and-the-new-apis), [DEV Community](https://dev.to/arshtechpro/iphone-duo-for-ios-developers-what-actually-changes-in-your-swift-code-5gc5): third-party point-size estimates; not Apple sources.
