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


# --- GigaMIDI -------------------------------------------------------------------------
# GigaMIDI has no bossa nova or lo-fi label at all (checked 2026-11-15: 0 files). Bossa nova
# is found by artist and by standard song titles; lo-fi is approximated by hip-hop, downtempo
# and jazz-family labels at slow tempos.

import re
import unicodedata

_LABEL_ALIASES = {
    "hip_hop": "hiphop", "hip-hop-rap": "hiphop", "hip hop rap": "hiphop", "rap": "hiphop",
    "randb": "rnb", "rnb-soul": "rnb", "latino": "latin", "brazil": "latin",
}

BOSSA_ARTISTS = re.compile(
    r"jobim|joao gilberto|astrud gilberto|bebel gilberto|stan getz|vinicius de moraes|bonfa|"
    r"sergio mendes|baden powell|carlos lyra|menescal|marcos valle|nara leao|joao donato|"
    r"tamba trio|walter wanderley|laurindo almeida|charlie byrd|toquinho|edu lobo")
BOSSA_TITLES = re.compile(
    r"ipanema|desafinado|corcovado|quiet nights|agua de beber|one.note.samba|samba de uma nota|"
    r"chega de saudade|insensatez|how insensitive|meditacao|dindi|mas que nada|manha de carnaval|"
    r"black orpheus|so danco samba|aguas de marco|waters of march|a felicidade|samba de verao|"
    r"summer samba|o barquinho|bossa|berimbau|samba de orfeu|once i loved|vivo sonhando|ela e carioca")
# Brazilian popular music close to bossa nova, and anything explicitly a samba
MPB_ARTISTS = re.compile(
    r"chico buarque|caetano veloso|djavan|gal costa|elis regina|gilberto gil|milton nascimento|"
    r"ivan lins|jorge ben|joao bosco|maria bethania|tom ze|ary barroso")
SAMBA_TITLES = re.compile(r"samba|aquarela do brasil")

LOFI_CORE_LABELS = {"hiphop", "downtempo"}
LOFI_WIDE_LABELS = {"jazz", "rnb", "funk", "soul"}
LOFI_TEMPO = (55, 105)


def _plain(text):
    return unicodedata.normalize("NFKD", (text or "").lower()).encode("ascii", "ignore").decode()


def gigamidi_labels(styles):
    """Flatten GigaMIDI's label columns (some hold comma-joined lists) into one canonical set."""
    out = set()
    for values in styles.values():
        for value in values:
            for part in re.split(r",|%2c", value):
                part = part.strip()
                if part:
                    out.add(_LABEL_ALIASES.get(part, part))
    return out


def classify_gigamidi(row):
    """Return [(style, tier)] for one row of data/gigamidi_styles.jsonl."""
    artist, title = _plain(row.get("artist")), _plain(row.get("title"))
    labels = gigamidi_labels(row.get("styles") or {})
    tempo = row.get("tempo")
    out = []

    if BOSSA_ARTISTS.search(artist) or BOSSA_TITLES.search(title):
        out.append(("bossa", "core"))
    elif MPB_ARTISTS.search(artist) or SAMBA_TITLES.search(title) or "latin" in labels:
        out.append(("bossa", "wide"))

    if tempo is not None and LOFI_TEMPO[0] <= tempo <= LOFI_TEMPO[1]:
        if labels & LOFI_CORE_LABELS:
            out.append(("lofi", "core"))
        elif labels & LOFI_WIDE_LABELS:
            out.append(("lofi", "wide"))
    return out
