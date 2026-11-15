"""Style filter rules: which files count as lo-fi or bossa nova.

Each style has two tiers:
  core - tagged as the style itself
  wide - neighbouring genres, used when core is too small to fine-tune on

MidiCaps genre tags come from an audio tagger using the MTG-Jamendo genre
vocabulary (e.g. "bossanova", "chillout", "triphop", "jazz", "hiphop").
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Style:
    name: str
    core_tags: frozenset
    wide_tags: frozenset
    caption_keywords: tuple
    # BPM window applied to the wide tier only; core tags are trusted as-is.
    wide_tempo: tuple
    # Groove MIDI Dataset style prefixes (its "style" column, e.g. "latin/brazilian-bossa")
    groove_core: tuple
    groove_wide: tuple
    # GuitarSet style codes (BN, Jazz, Funk, Rock, SS)
    guitarset_core: tuple
    guitarset_wide: tuple


STYLES = {
    "bossa": Style(
        name="bossa",
        core_tags=frozenset({"bossanova"}),
        wide_tags=frozenset({"latin", "jazz", "lounge", "easylistening"}),
        caption_keywords=("bossa",),
        wide_tempo=(90, 180),
        groove_core=("latin/brazilian-bossa",),
        groove_wide=("latin/brazilian", "latin"),
        guitarset_core=("BN",),
        guitarset_wide=("Jazz",),
    ),
    "lofi": Style(
        name="lofi",
        core_tags=frozenset({"chillout", "triphop", "downtempo"}),
        wide_tags=frozenset({"hiphop", "jazz", "soul", "rnb", "lounge", "funk"}),
        caption_keywords=("lo-fi", "lofi", "lo fi"),
        wide_tempo=(60, 100),
        groove_core=("hiphop",),
        groove_wide=("jazz", "soul", "neworleans/funk"),
        guitarset_core=(),
        guitarset_wide=("Jazz",),
    ),
}

TIME_SIGNATURES = {"4/4", "2/4", "2/2"}


def classify_tags(genres, caption, tempo, time_signature):
    """Return [(style, tier)] for a tagged multitrack file (MidiCaps-style metadata)."""
    if time_signature and time_signature not in TIME_SIGNATURES:
        return []
    genres = {g.lower() for g in genres or ()}
    caption = (caption or "").lower()
    out = []
    for style in STYLES.values():
        if genres & style.core_tags or any(k in caption for k in style.caption_keywords):
            out.append((style.name, "core"))
        elif genres & style.wide_tags:
            lo, hi = style.wide_tempo
            if tempo is None or lo <= tempo <= hi:
                out.append((style.name, "wide"))
    return out


def classify_prefix(value, core, wide):
    """Tier for a single label matched by prefix (Groove styles, GuitarSet codes)."""
    if any(value.startswith(p) for p in core):
        return "core"
    if any(value.startswith(p) for p in wide):
        return "wide"
    return None
