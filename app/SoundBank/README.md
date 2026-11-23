# Sound bank (iOS)

`GeneralUser-GS.sf2` is GeneralUser GS v2.0.3 by S. Christian Collins, downloaded from
https://github.com/mrbumpy409/GeneralUser-GS at commit `684543d5e5efaef08d02be50dcda8d552478fa60`
(32,319,396 bytes, SHA-256 `9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe`).
Its license is in `LICENSE-GeneralUser-GS.txt`.

It is a resource of the `LofiBossaiOS` target only. iOS has no built-in General MIDI bank, so
`AudioEngine` loads every track's program from this file there. The Mac keeps using the system
`gs_instruments.dls`. All programs in `TrackID.instruments` are present at their General MIDI
numbers, and the drum kits (Standard 0, Room 8, Jazz 32, Brush 40) are in the percussion
bank 128. `LofiBossaTests/BundledSoundBankTests.swift` checks both.
