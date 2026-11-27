"""The license of each data source, and the filter behind `--licenses`.

    --licenses cc-by    only sources under CC BY 4.0 or something more permissive (CC0)
    --licenses all      everything in the manifest (the default; includes GigaMIDI, CC BY-NC)

Models that ship in the app must be trained with `--licenses cc-by`. See DATA_LICENSES.md.
"""

# SPDX-style id per manifest `source`
SOURCE_LICENSE = {
    "lakh": "CC-BY-4.0",        # Lakh MIDI Dataset (Raffel 2016)
    "groove": "CC-BY-4.0",      # Groove MIDI Dataset (Gillick et al. 2019)
    "guitarset": "CC-BY-4.0",   # GuitarSet (Xi et al. 2018), Zenodo record 3371780
    "gigamidi": "CC-BY-NC-4.0", # GigaMIDI: non-commercial, gated, may hold copyrighted MIDI
    "midicaps": "CC-BY-SA-4.0", # MidiCaps captions over Lakh files
    "kaggle_lofi": "unknown",
}

# licenses each --licenses choice allows (None: no filtering)
LICENSE_GROUPS = {
    "cc-by": frozenset({"CC0-1.0", "CC-BY-4.0"}),
    "all": None,
}


def allowed(source, group="all"):
    """True if files from `source` may be used under the license group. Unknown sources are
    only allowed with "all"."""
    licenses = LICENSE_GROUPS[group]
    return licenses is None or SOURCE_LICENSE.get(source, "unknown") in licenses


def filter_rows(rows, group="all"):
    """Keep only manifest/index rows whose source the license group allows."""
    return [r for r in rows if allowed(r["source"], group)]
