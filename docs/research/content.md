# Content assets, sources and licences (Daily Duas)

Researched and verified on 2026-10-06. Everything marked **verified** was checked against the downloaded
file, a live HTTP response or the live source page. Anything marked **UNVERIFIED** was not.

Scripts used (scratchpad, not part of the project):
`C:\Users\Ahsan\AppData\Local\Temp\claude\D--Coding-Python-duas-app\72dc74bd-e89d-43a5-8d12-e5f34d2658d7\scratchpad\content\`
(`analyze_tanzil.py`, `get_amiri.py`, `font_cov.py`, `mp3dur.py`, `ea_listing.py`, `ea_sizes.py`,
`hadith_fetch.py`, `make_seed.py`, `norm_test.py`). To rebuild the seed JSON, run `make_seed.py` with the venv
Python. It needs network access because it fetches the hadith text again.

## 1. Bundled files (total about 2.2 MB)

| Path (under `src/`) | Bytes | Licence | Notes |
|---|---:|---|---|
| `assets/quran/quran-simple.txt` | 1,353,105 | Tanzil terms (CC BY 3.0 + no changes) | SHA-256 `c8c2ea9e004cf3f4b7afc5ba00de859556f4ed09bd9cf5d1bc79e877406ef678` |
| `assets/quran/LICENSE-tanzil.txt` | 2,515 | — | Where the file came from, plus the copyright block copied word for word |
| `assets/fonts/Amiri-Regular.ttf` | 437,780 | SIL OFL 1.1 | Amiri 1.003, SHA-256 `cd2550c0…2c43c0` |
| `assets/fonts/Amiri-Bold.ttf` | 414,560 | SIL OFL 1.1 | Amiri 1.003, SHA-256 `8cfed49b…92e79a` |
| `assets/fonts/OFL-Amiri.txt` | 4,389 | — | OFL.txt from the release zip, unchanged |
| `app/data/seed_duas.json` | 11,663 | see §5 | 6 items |
| `app/data/seed_routines.json` | 648 | — | 2 routines |

The release zip was read in memory and never saved to disk. No zip files are left anywhere.

## 2. Tanzil Quran text

### Source and options (verified)
- Download page: https://tanzil.net/download/. The form submits a GET request to `/pub/download/index.php`.
- A checkbox is sent only when it is ticked, so if you leave it out of the URL, the option is **off**.
  The URL suggested in the task (`?quranType=simple&outType=txt-2&agree=true`) therefore downloads the text
  **without** pause marks, sajdah signs or tatweel (1,338,090 bytes). That copy was not used.
- The URL used matches the form's default ticks (marks, sajdah and tatweel on; rub-el-hizb off):
  `https://tanzil.net/pub/download/index.php?marks=true&sajdah=true&tatweel=true&quranType=simple&outType=txt-2&agree=true`
- Text type is `simple` (Imla'ei script with full tashkeel). It is **not** `simple-clean`. The release is Version 1.1 (February 2021).
  The site footer says © 2007-2026.

### Format (verified)
- UTF-8, no BOM, LF only (no CR), one line per verse: `sura|aya|text`. Split with `line.split("|", 2)`.
- After verse 114:6 come two blank lines and then a block of 28 lines starting with `#` (the copyright notice).
  A parser must skip empty lines and lines starting with `#`.
- The file has **6236 verses** and **114 suras**. Ayah numbers run without gaps within each sura (sura 2 has 286, sura 114 has 6).
- Words are separated by a single U+0020. No line has leading, trailing or double spaces.

### Licence (verified, copied word for word into `LICENSE-tanzil.txt`)
The header says "License: Creative Commons Attribution 3.0". The terms of use add conditions on top of that:
"Permission is granted to copy and distribute verbatim copies of this text, but CHANGING IT IS NOT ALLOWED";
the source (Tanzil Project) must be clearly indicated, with a link to tanzil.net; and the notice must be included with
verbatim copies and "reproduced appropriately in all files derived from or containing substantial portion of this
text". In practice this works like CC BY-ND:
- Keep `quran-simple.txt` byte-identical and never edit it.
- Show the attribution string from §7 in the app.
- Every Quran item in the seed JSON names Tanzil in its `notes`. These are short excerpts, not a substantial portion.

### Bismillah handling (verified)
- **1:1 is the Bismillah** (`بِسْمِ اللَّهِ الرَّحْمَـٰنِ الرَّحِيمِ`). It is an ayah in its own right.
- **For every other sura except 9, the text of ayah 1 starts with the Bismillah**, followed by a single space and
  then the actual ayah. Example: `112|1|بِسْمِ اللَّهِ الرَّحْمَـٰنِ الرَّحِيمِ قُلْ هُوَ اللَّهُ أَحَدٌ`.
  - 110 suras use exactly the same prefix as 1:1.
  - **Suras 95 and 97 use a different prefix, `بِّسْمِ …`, with a shadda on the ba.** This marks the idgham
    into the last letter of the previous sura. A check that compares the prefix to 1:1 exactly misses these two.
  - **Sura 9 has no Bismillah.**
  - 27:30 contains the Bismillah in the middle of the ayah. It is part of the ayah and must not be removed.
- **Stripping rule:** for ayah 1 of any sura other than 1 and 9, drop the first 4 space-separated words.
  The script checks that their letters, with marks removed, are `بسم الله الرحمن الرحيم`.
- The seed JSON stores **ayahs without the Bismillah prefix**. Each Quran item's `notes` says so.
- To display the Bismillah above a sura, render 1:1 separately. Do not keep the prefix inside ayah 1.

### Characters present in the verse text (verified census of all 6236 verses, 55 distinct code points)

Non-letter code points:

| Code point | Count | Cat | Name |
|---|---:|---|---|
| U+0020 | 76391 | Zs | SPACE |
| U+0640 | 939 | Lm | ARABIC TATWEEL (always directly followed by U+0670) |
| U+064B | 3742 | Mn | ARABIC FATHATAN |
| U+064C | 2519 | Mn | ARABIC DAMMATAN |
| U+064D | 2633 | Mn | ARABIC KASRATAN |
| U+064E | 121886 | Mn | ARABIC FATHA |
| U+064F | 37320 | Mn | ARABIC DAMMA |
| U+0650 | 46642 | Mn | ARABIC KASRA |
| U+0651 | 23016 | Mn | ARABIC SHADDA |
| U+0652 | 37372 | Mn | ARABIC SUKUN |
| U+0670 | 3330 | Mn | ARABIC LETTER SUPERSCRIPT ALEF (after ى ×1912, after tatweel ×939, after fatha ×479) |
| U+06D6 | 1682 | Mn | SMALL HIGH LIGATURE SAD WITH LAM WITH ALEF MAKSURA (waqf: continuing preferred) |
| U+06D7 | 603 | Mn | SMALL HIGH LIGATURE QAF WITH LAM WITH ALEF MAKSURA (waqf: stopping preferred) |
| U+06D8 | 22 | Mn | SMALL HIGH MEEM INITIAL FORM (waqf lazim) |
| U+06D9 | 68 | Mn | SMALL HIGH LAM ALEF (do not stop) |
| U+06DA | 1972 | Mn | SMALL HIGH JEEM (stopping permitted) |
| U+06DB | 12 | Mn | SMALL HIGH THREE DOTS (mu'anaqah, paired) |
| U+06DC | 5 | Mn | SMALL HIGH SEEN |
| U+06E9 | 15 | So | ARABIC PLACE OF SAJDAH (last token of the 15 sajdah verses) |

Letters (category Lo) with counts:
U+0621 ء 1578, U+0622 آ 1511, U+0623 أ 9119, U+0624 ؤ 673, U+0625 إ 5108, U+0626 ئ 1182, U+0627 ا 43875,
U+0628 ب 11603, U+0629 ة 2344, U+062A ت 10520, U+062B ث 1414, U+062C ج 3317, U+062D ح 4364, U+062E خ 2497,
U+062F د 5991, U+0630 ذ 4932, U+0631 ر 12627, U+0632 ز 1599, U+0633 س 6124, U+0634 ش 2124, U+0635 ص 2072,
U+0636 ض 1686, U+0637 ط 1273, U+0638 ظ 853, U+0639 ع 9405, U+063A غ 1221, U+0641 ف 8747, U+0642 ق 7034,
U+0643 ك 10497, U+0644 ل 38639, U+0645 م 27071, U+0646 ن 27382, U+0647 ه 14962, U+0648 و 24813,
U+0649 ى 2595, U+064A ي 22085.

The file does **not** contain any of the following: U+0671 alef wasla, U+0653 maddah, U+0654/U+0655 combining hamza,
U+06E1 dotless khah head, U+06E2 iqlab meem, U+06E5/U+06E6 small waw/yeh, U+06DD end-of-ayah sign,
U+06DE rub-el-hizb, U+08F0–U+08F2 sequential tanween, U+06CC Farsi yeh, U+06A9 keheh, ZWJ/ZWNJ (U+200C/D),
RLM/LRM, NBSP, or any Arabic punctuation.
Outside the verse text the file also contains ASCII digits, `|`, LF and the ASCII `#` comment block.

Every pause or sajdah mark is a **separate token with spaces on both sides**. For example 2:127 has
`… مِنَّا ۖ إِنَّكَ …`, and the sajdah sign comes at the end: `… يَسْتَكْبِرُونَ ۩`. Word splitting must drop tokens
that contain only U+06D6–U+06ED.

### Fonts cover everything (verified)
Both Amiri files (fontRevision 1.003) map every code point in the Tanzil file. They also cover U+060C, the Arabic-Indic digits, ﴾﴿,
ASCII and the hadith text. This was checked with a small cmap reader (`font_cov.py`); fontTools was not installed.

## 3. Amiri font

- Downloaded from the official GitHub release https://github.com/aliftype/amiri/releases/tag/1.003
  (`Amiri-1.003.zip`, 1,033,533 bytes, published 2025-06-13). This is the "latest" release per the GitHub API on 2026-10-06.
  Only `Amiri-Regular.ttf`, `Amiri-Bold.ttf` and `OFL.txt` (saved as `OFL-Amiri.txt`) were extracted.
- Licence: SIL Open Font License 1.1, "Copyright 2010-2022 The Amiri Project Authors (https://github.com/aliftype/amiri)".
  Bundling and redistributing the font in an app is allowed. The licence text must ship with it (done).
  The font must not be sold on its own, and a modified version must not be called "Amiri".
- The upstream README says development is finished: version 1 is considered mature.
- The zip also contains `AmiriQuran.ttf` (136,920 bytes), a font specialised for Quran text. It was **not** bundled because the task
  asked for Regular and Bold. If space matters a lot, it could replace both. UNVERIFIED: its Latin and punctuation coverage.
- Flet: `page.fonts` is `dict[str, str]` and holds **one file per family**
  (verified in `flet/controls/page.py`). Register two families,
  `page.fonts = {"Amiri": "fonts/Amiri-Regular.ttf", "Amiri Bold": "fonts/Amiri-Bold.ttf"}` (paths relative to
  the `assets` dir). Then use `font_family="Amiri Bold"` instead of `weight=BOLD`, which would give a synthetic bold.

## 4. Recitation audio

### everyayah.com (recommended)
- **URL scheme (verified):** `https://everyayah.com/data/<folder>/<SSSAAA>.mp3`, where SSS is the sura and AAA the ayah,
  each zero-padded to 3 digits. Examples: 2:255 is `002255.mp3`, 112:1 is `112001.mp3`.
  - `http://` redirects to `https://` with a 301. `www.everyayah.com` also works. The CDN is BunnyCDN.
  - A file that does not exist returns **404** (`text/html`), never a "soft 200". Existing files return `200`,
    `audio/mpeg`, `Accept-Ranges: bytes`, `Cache-Control: max-age=25600000` and `Access-Control-Allow-Origin: *`.
  - Machine-readable list of reciters: https://everyayah.com/data/recitations.js. It is JSON despite the name: an `ayahCount` list of 114 entries
    (sum 6236) followed by 79 entries `{subfolder, name, bitrate}`.
- **Basmala (verified by measuring durations; not listened to):**
  - Per-ayah files do **not** include the basmala. Duration of 112001.mp3: Alafasy 3.00 s, Minshawy 3.21 s, Abdul Basit 3.16 s,
    Sudais 2.95 s, Shuraym 2.01 s, Maher 1.91 s. Each reciter's basmala (001001.mp3) is 2.8–6.1 s.
    Husary is slow: 112001 is 5.83 s against a basmala of 5.12 s. The two together would be at least 9 s, so his file has no basmala either.
  - **`001001.mp3` (Al-Fatiha 1:1) is the basmala and is the only basmala clip that every folder has.** Play it before
    ayah 1 if a basmala is wanted (never before sura 9).
  - `NNN000.mp3` files are inconsistent: Alafasy_128 has 112 of them, Abdul_Basit_192 has 114, Husary_128 has 1, Abdul_Basit_64 has 16 and Hudhaify_64 has 0.
    `bismillah.mp3` and `audhubillah.mp3` exist only in some folders. **Do not rely on any of these.**
    UNVERIFIED: what NNN000 contains (Alafasy 112000 is 6.6 s, similar to its 6.4 s bismillah.mp3).
- **Partial ayah:** the `acceptance` item is only part of 2:127, but everyayah has whole-ayah audio only. Either play nothing
  for that item or use Android TTS. Playing 002127.mp3 would recite the whole ayah.
- **Terms of use (verified that none exist):** the site publishes no licence or terms page. "Contact Us" links to
  https://quran.zendesk.com/hc/en-us, which is the Quran.com / Quran Foundation help centre.
  The only explicit terms found are in `data/timings_files/000_disclaimer.txt`: "(C) VerseByVerseQuran.com. You must
  link back to our site …". That applies to the timing files. The licence URL it cites, versebyversequran.com/site/license, returns 404.
  The recordings belong to the reciters and producers. For a personal, sideloaded app it is reasonable to stream or cache the files for
  personal use and credit "EveryAyah.com" and the reciter (§7). The app should not redistribute the MP3s, for example by bundling them in the APK.

#### Curated reciters (every folder verified complete: all 6236 `SSSAAA.mp3` present, plus a HEAD request for 112001)
Download size for all 17 ayah files the seed routines use (112:1-4, 113:1-5, 114:1-6, 2:255, 2:127),
from HEAD Content-Length:

| Reciter (display name) | Low-disk folder (default) | KiB | Higher-quality folder | KiB |
|---|---|---:|---|---:|
| Mishary Rashid Alafasy | `Alafasy_64kbps` | 1171 | `Alafasy_128kbps` | 2316 |
| Abdul Basit Abdus-Samad (Murattal) | `Abdul_Basit_Murattal_64kbps` | 1154 | `Abdul_Basit_Murattal_192kbps` | 3423 |
| Mahmoud Khalil Al-Husary | `Husary_64kbps` | 1542 | `Husary_128kbps` | 3120 |
| Mohamed Siddiq Al-Minshawi (Murattal) | — | — | `Minshawy_Murattal_128kbps` | 2370 |
| Abdur-Rahman As-Sudais | `Abdurrahmaan_As-Sudais_64kbps` | 892 | `Abdurrahmaan_As-Sudais_192kbps` | 2686 |
| Saud Ash-Shuraim | `Saood_ash-Shuraym_64kbps` | 746 | `Saood_ash-Shuraym_128kbps` | 1466 |
| Maher Al-Muaiqly | `Maher_AlMuaiqly_64kbps` | 800 | `MaherAlMuaiqly128kbps` (note: no underscores) | 1565 |
| Ali Al-Hudhaify | `Hudhaify_64kbps` | 1192 | `Hudhaify_128kbps` | 2366 |

- Default: `Alafasy_64kbps`. The user wants minimal disk use, so default to the 64 kbps folders and offer 128/192 as an option.
- Minshawy has no complete low-bitrate Murattal folder: `Menshawi_32kbps` is missing 303 files, and `Menshawi_16kbps` is too poor in quality.
- The bitrate in a folder name is nominal. For example `Alafasy_128kbps/001001.mp3` is really 192 kbps, and Maher's 001001 is VBR. The
  folders also contain stray files such as `Saood_ash-Shuraym_*/012112.mp3` and `091016.mp3` for ayahs that do not exist. Only build URLs from
  valid sura and ayah numbers.
- Caching suggestion: save to `<app data>/audio/<folder>/<SSSAAA>.mp3`, download only the ayahs that routines need, and
  delete a reciter's folder when the user switches reciter.

### Quran Foundation (quran.com) Content API (alternative, not recommended here)
Taken from https://api-docs.quran.foundation/docs/quickstart/ and https://api-docs.quran.foundation/legal/developer-terms/
on 2026-10-06:
- You must register an app in the Developer Console (https://dev-console.quran.foundation). Authentication is **OAuth2 client
  credentials** (`grant_type=client_credentials&scope=content`) against `https://oauth2.quran.foundation/oauth2/token`
  (pre-live: `prelive-oauth2…`). Every request needs the headers `x-auth-token` and `x-client-id`. Tokens last 3600 s
  and there are no refresh tokens. The API base is `https://apis.quran.foundation`.
- The docs say: "Keep client_secret on the server only", and mobile apps must not embed it. That means running a backend.
- The developer terms (page shows "Last Updated: 2026-10-04"; a search snippet showed 2026-08-10, so the page changes often)
  forbid caching or storing QF Content "longer than 1 week" unless you use their Content Sync APIs. They also require crediting
  Quran Foundation and forbid modifying the Quran text. They grant a revocable, non-transferable licence.
- **Recommendation: use everyayah.com.** It needs no key or backend, serves static, long-cacheable files and lets the app keep
  audio offline for alarms. Quran Foundation would add OAuth, a server for the secret and a one-week cache limit, none of which a
  personal sideloaded app needs.

## 5. Seed content (`src/app/data/seed_duas.json`, `seed_routines.json`)

Each item has exactly these fields, in this order: `key, title, arabic, ayahs, transliteration, translation, source, category,
default_repeat, quran, verification_status, notes`. `make_seed.py` checks all of the following:
- `arabic == " ".join(ayahs)` whenever `ayahs` is not null.
- Each element of `ayahs` equals the Tanzil verse, with the Bismillah prefix removed from ayah 1.
  For an item whose notes say "partial ayah", it must instead be a substring of the verse.
- No item's `arabic` starts with `بِسْمِ`.
- Every `dua_key` in the routines exists.
- No ayah-end numbering (﴿١﴾) is inserted anywhere. The ayah boundaries live only in the `ayahs` list.

`transliteration` and `translation` are single strings that cover the ayahs in order, separated by single spaces.
The English is **written for this app**: it is a faithful, plain rendering and does not copy Saheeh International or any other
published translation.

| key | Source | Category | Repeat | Status |
|---|---|---|---:|---|
| `al_ikhlas` | Quran 112:1-4 | Protection | 3 | verified |
| `al_falaq` | Quran 113:1-5 | Protection | 3 | verified |
| `an_nas` | Quran 114:1-6 | Protection | 3 | verified |
| `ayat_al_kursi` | Quran 2:255 | Protection | 1 | verified |
| `kalimat_tammah` | Sahih al-Bukhari 3371 | Evil eye | 3 | **unverified** (until the user confirms) |
| `acceptance` | Quran 2:127 (partial ayah) | Acceptance | 1 | verified |

Routines: `morning` is Ayat al-Kursi ×1, Al-Ikhlas ×3, Al-Falaq ×3, An-Nas ×3. `evil_eye` is `kalimat_tammah` ×3,
Al-Falaq ×3, An-Nas ×3.
Background, not stored in the JSON: reciting Al-Ikhlas and the two Mu'awwidhat three times each morning and evening comes from
Sunan Abi Dawud 5082 and Jami' at-Tirmidhi 3575 (graded hasan). Checked against the hadith-api dataset.

### The evil-eye hadith (important finding)
- **The task premise was partly wrong.** In Sahih al-Bukhari 3371 itself (Book of the Prophets, in-book 60/45), the wording is
  first person. Ibn Abbas says the Prophet ﷺ used to seek refuge for al-Hasan and al-Husayn and said:
  إِنَّ أَبَاكُمَا كَانَ يُعَوِّذُ بِهَا إِسْمَاعِيلَ وَإِسْحَاقَ، أَعُوذُ بِكَلِمَاتِ اللَّهِ التَّامَّةِ مِنْ كُلِّ شَيْطَانٍ وَهَامَّةٍ، وَمِنْ كُلِّ عَيْنٍ لاَمَّةٍ
  So the stored first-person text **is the Bukhari wording**, not an adaptation of it.
- The second-person wording `أُعِيذُكُمَا بِكَلِمَاتِ اللَّهِ التَّامَّةِ مِنْ كُلِّ شَيْطَانٍ وَهَامَّةٍ وَمِنْ كُلِّ عَيْنٍ لاَمَّةٍ`
  (U'idhukuma …) is the version in **Sunan Abi Dawud 4737** (al-Albani: sahih) and **Jami' at-Tirmidhi 2060**
  (at-Tirmidhi: hasan sahih; al-Albani: sahih). These grades come from the hadith-api dataset.
  **Sunan Ibn Majah 3525** has the first-person `أَعُوذُ` form.
- Sources: sunnah.com returns a Cloudflare "Just a moment…" page (HTTP 403) to scripts, and that check was **not** bypassed.
  The Arabic was taken programmatically from the fawazahmed0/hadith-api dataset (sunnah.com-derived),
  `https://cdn.jsdelivr.net/gh/fawazahmed0/hadith-api@1/editions/ara-bukhari/3371.json`. It was then compared letter by letter
  with an independent copy at https://en.tohed.com/hadith/bukhari/3371. The letters and harakat are identical; the only
  differences are the Arabic comma ، (present in the dataset, absent on tohed) and how the fatha of لَامَّةٍ is encoded.
- Encoding changes made to the stored text: removed RLM (U+200F) and quotation marks; changed `لاَمَّةٍ`
  (U+0644 U+0627 U+064E, fatha typed after the alef, a legacy habit) to `لَامَّةٍ` (U+0644 U+064E U+0627). The reading
  does not change. The stored text equals the form given in the task under NFC.
- No repetition count appears in the hadith. ×3 is the user's own choice for the routine (stated in `notes`).
- dorar.net (another reference) also returned 403 to scripted fetches, so it was not checked.

## 6. Comparing LLM-typed Arabic with Tanzil Simple: normalization pitfalls

Verified with `norm_test.py`. **Byte equality and even "strict" equality with harakat kept fail on real LLM output**, as the
Al-Ikhlas, 2:127 and An-Nas tests showed. Compare on a letter skeleton instead. Best of all, ask the LLM only for
`surah:ayah` references and take the text from Tanzil.

1. **Mark order.** Tanzil stores **shadda before the vowel** (`ل U+0651 U+064E`) in all 23,016 cases. Unicode
   canonical order puts the vowel first (fatha ccc 30 < shadda ccc 33), and keyboards and LLMs usually produce that. The Tanzil text is
   **not NFC**: NFC changes 5,657 of 6,236 verses. Normalize **both** sides with NFC before any strict comparison.
   Python `str.find` on hand-typed Arabic fails because of this; it happened while building the seed.
2. **NFD/NFKD decomposition.** `أ` U+0623 decomposes to `ا` U+0627 + U+0654 (likewise آ to ا+U+0653, إ to ا+U+0655,
   ؤ to و+U+0654, ئ to ي+U+0654). Prefer NFC. If you decompose and then strip marks, hamza information is lost silently.
3. **Harakat and tanween:** U+064B–U+0652 (fathatan, dammatan, kasratan, fatha, damma, kasra, shadda, sukun). Related ranges to strip
   for a skeleton: U+0653–U+065F (maddah, hamza above/below, subscript alef U+0656, inverted damma and others) and U+0610–U+061A
   (honorific signs and small marks above letters).
4. **Superscript (dagger) alef U+0670**, 3,330 times: `عَلَىٰ`-type words (after ى), `الرَّحْمَـٰنِ`, `إِلَـٰهَ`
   (after tatweel) and `ذَٰلِكَ`/`هَٰذَا` (after fatha). LLMs may omit it, write a full alef (`الرحمان`) or put it
   directly on the consonant without a tatweel. Strip U+0670 for the skeleton. A full-alef spelling still will not match.
5. **Tatweel U+0640**, 939 times, always before U+0670 because the tatweel option is on. Strip it. LLMs sometimes add it as kashida.
6. **Quranic annotation marks U+06D6–U+06ED.** Tanzil Simple uses only U+06D6–U+06DC (waqf signs) and U+06E9 (sajdah), each as a
   **space-separated token**. Uthmani text from quran.com or LLM output can also contain U+06DF (rounded zero), U+06E0, U+06E1
   (sukun shaped like a khah head), U+06E2 (iqlab meem), U+06E3 (small low seen), U+06E5/U+06E6 (small waw/yeh), U+06E7, U+06E8
   (small high noon), U+06EA–U+06ED, U+06DD (end of ayah), U+06DE (rub-el-hizb). Strip them and then **collapse whitespace**,
   because removing a standalone mark leaves a double space.
7. **Ikhfa and idgham shown in the Simple text:** the noon before an idgham or ikhfa letter has **no sukun**, and the next letter
   carries a **shadda**: `مِن شَرِّ`, `أَنتَ`, `يَكُن لَّهُ`, `بِشَيْءٍ مِّنْ`. An LLM writes `مِنْ شَرِّ`, `أَنْتَ`, `يَكُنْ لَهُ`.
   These differ only in marks, which is another reason to compare on the skeleton.
8. **Alef variants:** ا U+0627, أ U+0623, إ U+0625, آ U+0622, ٱ U+0671 (wasla, which Simple does not use but Uthmani does), ٲ U+0672, ٳ U+0673.
   For a lenient skeleton, fold them all to U+0627. LLMs often drop hamza seats (`اعوذ`).
9. **Hamza forms:** ء U+0621 on its own line, ؤ U+0624, ئ U+0626, and combining U+0654/U+0655. The lenient skeleton maps ؤ to و
   and ئ to ي and removes a standalone ء. Without this, `شيء`/`شي` and `شاء`/`شا` differ.
10. **Alef maqsura and yeh:** Tanzil uses ى U+0649 (2,595 times, e.g. `عَلَى`, `إِلَى`, `مُوسَىٰ`) and ي U+064A. LLMs or Persian
    keyboards may use ی U+06CC (Farsi yeh) or ے U+06D2, or swap ى and ي. Fold all of them to U+064A.
11. **Ta marbuta** ة U+0629 against heh ه U+0647 at the end of a word: fold ة to ه in the lenient skeleton.
    Also fold Persian keheh ک U+06A9 to ك U+0643.
12. **Lam-alef encoding:** sources such as the sunnah.com data write `لاَ` (fatha after the alef) where Tanzil writes `لَا`.
    Stripping marks makes them equal.
13. **Invisible and bidi characters:** RLM U+200F, LRM U+200E, ALM U+061C, ZWJ/ZWNJ U+200D/U+200C, ZWSP U+200B,
    BOM U+FEFF, embeddings U+202A–U+202E and isolates U+2066–U+2069. These are common in copied hadith text (the
    sunnah.com data has U+200F around quotation marks). Remove them.
14. **Punctuation, digits and ornaments:** ، U+060C, ؛ U+061B, ؟ U+061F, ۔ U+06D4, ﴾﴿ U+FD3E/U+FD3F, Arabic-Indic digits
    U+0660–U+0669, extended digits U+06F0–U+06F9, ASCII punctuation and digits, and guillemets. Replace them with spaces.
15. **Presentation forms and ligatures:** U+FB50–U+FDFF and U+FE70–U+FEFF, such as ﷲ U+FDF2, which NFKC turns into `الله`, and
    ﷺ U+FDFA. Apply **NFKC first** in the skeleton function only.
16. **Sequential tanween** U+08F0–U+08F2 and other Extended-A marks in U+08D3–U+08FF appear in some Uthmani fonts and data. Strip them.
17. **Uthmani spelling differs from Imla'i in its letters as well as its marks.** For example `ٱلسَّمَـٰوَٰتِ`/`السَّمَاوَاتِ`,
    `ٱلصَّلَوٰةَ`/`الصَّلَاةَ` and `إِبْرَٰهِـۧمَ`/`إِبْرَاهِيمَ` remain different after skeleton normalization (verified).
    Ask the LLM for Imla'i ("simple") script, or use a similarity threshold rather than equality.

Reference skeleton function (tested: LLM-style, Uthmani-style and bare-letter versions of Al-Ikhlas, An-Nas, 2:127 and the
hadith all match the seed text):

```python
import re, unicodedata
_MARKS = re.compile("[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06DC\u06DF-\u06E4\u06E7\u06E8\u06EA-\u06ED\u08D3-\u08FF]")
_DROP = re.compile("[\u0640\u06DD\u06DE\u06E9\u200B-\u200F\u202A-\u202E\u2066-\u2069\u061C\uFEFF]")
_PUNCT = re.compile("[\u060C\u061B\u061F\u06D4.,;:!?\"'()\\[\\]{}\u00AB\u00BB\uFD3E\uFD3F\u0660-\u0669\u06F0-\u06F90-9\\-]")
_FOLD = str.maketrans({"\u0622": "\u0627", "\u0623": "\u0627", "\u0625": "\u0627", "\u0671": "\u0627",
                       "\u0672": "\u0627", "\u0673": "\u0627", "\u0649": "\u064A", "\u06CC": "\u064A",
                       "\u06D2": "\u064A", "\u0629": "\u0647", "\u06A9": "\u0643"})

def skeleton(text: str) -> str:
    t = unicodedata.normalize("NFKC", text)
    t = _DROP.sub("", t)
    t = _MARKS.sub("", t)
    t = _PUNCT.sub(" ", t)
    t = t.replace("\u06E5", "").replace("\u06E6", "")
    t = t.translate(_FOLD).replace("\u0624", "\u0648").replace("\u0626", "\u064A").replace("\u0621", "")
    return " ".join(t.split())
```

For strict display-level comparison, use `" ".join(re.sub("[\u06D6-\u06ED]", "", unicodedata.normalize("NFC", t)).split())`
after removing tatweel and bidi characters. Expect this to fail because of point 7.

## 7. Attribution strings to show in the app (About / Credits)

Use these exact strings. `{reciter}` is the display name from the table in §4.

- `Quran text: Tanzil Project (Simple text, v1.1) — https://tanzil.net. Used verbatim under the Tanzil terms of use (CC BY 3.0; changing the text is not permitted).`
- `Arabic font: Amiri by The Amiri Project Authors — SIL Open Font License 1.1.`
- `Recitation audio: {reciter}, verse-by-verse recordings from EveryAyah.com.`
- `Hadith: Sahih al-Bukhari 3371 (Arabic text as published on sunnah.com).`
- `English meanings and transliterations were written for this app and are not a published translation.`

The Tanzil terms also require a link to tanzil.net, so make the URL in the first string tappable or at least visible.
