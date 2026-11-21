# Remaining scan issues, by the fix they need

Everything known to still go wrong in scans, sorted by what it takes to fix: code that looks at the page (no
model change), retraining the chord reader on RunPod (`NEXT_RUNPOD_RUN.md`), retraining another model, or a call
Jack has to make first. Each entry says where it was seen and what goes wrong for the user. Updated Nov 19 2026
(ScannerCore 0.1.21).

Rules for adding fixes (Jack): fix general causes, judged on the whole test set, never one chart; ask before a fix
that looks specific to one chart; show regression numbers, and say which checks were not run.

## Nov 19 stuff (from users' scores: Edelweiss, Candy, Just the Way You Are, a hymn)

Parked for later; not started. Seen Nov 19 2026 on 0.1.21.

| Issue | Seen in | Effect |
| --- | --- | --- |
| Multi-bar rests ("6", "3", "7" over a long rest) written as one bar | Candy (2nd alto part): 55 bars for 65 | every later bar misnumbered, D.S./Coda land wrong |
| Hymn verse number ("1. Now") takes the first note | "Now Let Us Rejoice", "Ein Licht in dir geborgen" ("1. Ein", "3. Ein" on the pickup) | first syllable missing, left as staff text |
| A word under two notes cut in two by the touching-words rule ("treibt" → "treil" / "ibt") | "Ein Licht in dir geborgen", verse 3 bar 4 | garbled syllables |
| A 9-8 suspension ("C9 – 8") written as a dominant ninth | "Ein Licht in dir geborgen" bar 13 | C9 plays a B♭ that is not there; Jack's call (Cadd9 then C?) |
| Dashed extension lines read into staff text ("play both times - - - ┐") | Just the Way You Are | junk characters in text |
| One-bar drum repeats (% with bar counts) read as empty bars | Just the Way You Are, bars 7-13 | drums silent |
| Handwritten jazz-font treble clef at line starts read as an alto clef | Candy, two systems | 7 bars a seventh low |
| Handwritten part name ("2nd E♭ Alto Saxophone") not read | Candy | no instrument, no transposition |
| "D.S. al Coda" in a handwritten font read as "D.S. S AL COOA" | Candy | no jump on playback |
| Boxed rehearsal numbers mostly missed (41 read as "4") | Candy | rehearsal marks missing |
| An accidental read as a key change (3 sharps for 2) | Candy, twice | wrong key for a bar or line |
| A part's page-2 header ("ALTO 2", "CANDY") read as staff text | Candy | stray text in the music |
| Octave-transposing instruments (guitar, bass guitar, double bass, piccolo) play at written pitch | any score naming them | guitar and bass an octave high |
| "Bass" in a band (beside guitar, drums, saxes) gets no instrument, or a choir bass beside a "Vocal" part | Just the Way You Are, The Lady Is a Tramp | default or wrong sound |
| A trumpet or clarinet part on its own (nothing to compare keys with) is not transposed | lone parts | plays at written pitch |
| Instrument names in Italian, French or German not recognised ("Flauto", "Fagotti", "Corno", "Violino", "Clarinetti in B") | Mozart 40 | default sound (transposition still comes from the key signatures) |
| Two staves of one page read as one two-staff part (Lady's 2nd and 3rd trombones on page 1) | The Lady Is a Tramp, page 1 | one extra part at that page turn |
| Part names with the key in front in short forms ("B♭ Tenor Sax", "E♭ Alto Sax", "E♭ Bari Sax") not recognised; Jack: leave it, the printed key is often missing or wrong. Idea to try: a name that contains "soprano/alto/tenor/bari/baritone sax(ophone)" is that sax (longest phrase wins, printed key ignored); saxes only for now | lone parts | no instrument, no transposition |
| A bass note missed or misread, differently on the Mac and the phone | Edelweiss bars 25 and 30 | wrong or missing note |
| Real Book lines still read as percussion: one page left after 0.1.23 (a page's first bar where the reader guessed percussion, in a lead sheet the 0.9 rule does not reach) | rb6 p.226 (47 notes) | notes become drum hits |
| A continuation page with no clef takes the reader's guess for its first bars | nrb2 p.148 (bass clef until a printed treble clef in bar 10) | wrong octave/clef for a few bars |
| Rubber stamps and page-2 headers on old photocopies (band name, owner's address) read as staff text | Girl from Ipanema ("HELSINGBORGS STORBAND", "SLATTERGATAN 3", "3ALTD SAX") | stray text in the music |
| A boxed rehearsal letter beside a word read together ("C" + "SOLI" → "CSOLI") | Girl from Ipanema | wrong text, rehearsal mark missing |
| Faint bar lines on a photocopy's last line missed, so 7 bars become 3 overfull "check bars" | Girl from Ipanema, last line | bars merged, playback stumbles |
| "Arranged by …" in a credits block joined to the composer instead of the arranger | Girl from Ipanema | credit in the wrong field |

## Nov 20: piano-vocal-guitar songbook pages (two photos from a songbook, test only)

First pages with guitar chord diagrams over the voice staff. Seen on 0.1.24/0.1.25.

| Issue | Seen in | Effect |
| --- | --- | --- |
| ~~Guitar chord grids boxed as words; the names above them mostly missed~~ | second song 22 -> 28 of 35 chords (not yet committed) | diagrams recognised and ignored; a name touching one split off; a name on one belongs to the staff below |
| A name joined to a diagram's open-string "o" under it reads as nothing (two D's in the second song) | second song | 2-3 chords missing; tried dropping small marks on the nut: no gain, cost a chord, taken out |
| First song's names are under a staff space tall and blurred onto their diagrams | first song: 9 of 19 | limit of the photo, left as is (Jack, Nov 20) |
| A slash bass printed under the grid ("(C# Bass)") never read | both songs | wrong root in playback |
| ~~A tilted bottom system reads its three staves as two~~ | second song, page 1 | fixed, not yet tagged (curled photos straightened) |
| ~~A curled first system not found in the app's PDF render (also in 0.1.24)~~ | second song, page 2 | fixed, not yet tagged: 30 of 30 bars |
| The outermost strip of a strongly curled page (the last 5% by the spine or edge) stays bent: a chord or note right at the edge can be missed | real-scan photos, Merry-Go-Round p2 | rare, left as is |
| "Words and Music by X" gives the composer "Words and Music" | both songs | wrong credit |
| "To Coda" read together with the chord name beside it | second song | no jump, junk text |
| Third song, Morning Has Broken (Nov 21): third system's voice split from its piano, its piano joined to the fourth system (30 of 33 bars, piano in 2 parts) | Morning Has Broken | fixed, uncommitted: 33 of 33, voice + piano |
| A part starting after the first system had no meter in bar 1 (4/4 assumed, hidden rests padded every staff) | Morning Has Broken; ~45 Real Book pages with a late second part | open: the fix was dropped Nov 21 (it broke the Matrix both ways tried); needs a narrower version |
| Dotted halves read as halves, lengthened by bar-fit but still written "half" (Aria spills the bar) | Morning Has Broken | fixed, uncommitted: written value follows the length |
| Chord names under a staff space tall in a 1,900 px photo (18 of 30 read); diagrams blur into pieces and come out as junk words the reader rejects | Morning Has Broken | limit of the photo: a sharper photo is the fix |
| Slurs on cue notes read as grace notes, with no note after them in the bar, crash MuseScore and Aria on open (segfault laying out the slur) | Singin' in the Bathtub (BandMusic flute part, Nov 21) | fixed, uncommitted: those slurs are dropped (`dropDanglingGraceSlurs`); 3 Real Book pages lose 1-2 slur marks |
| Verse labels ("1 & 4.") written as staff text | second song | stray text |

## 0. Top priority: bars that hold more than their time signature

Agreed with Jack, Nov 16 2026; partly built. Done: the validity pass (23a3d63) means MuseScore never refuses a
bar, and the reader keeps the model's runner-up note values and dots and tries them on overfull bars (30832b1,
8 fewer check bars, none new, no note lost). Not done: voice splits, tuplets and dropped notes in the search, and
missed bar lines; most of the check bars below are still there.

Today a bar that overflows its meter gets a time signature of its own
length and "check bar" (Tidy's `overflowMeters`). Nothing is lost, but playback gains a beat and the pulse
stumbles, like MuseScore's stretched tuplet bars. About 90 such bars in the test sets, nearly all on piano and
classical pages and real phone scans (27 in 3 of the 11 real charts); lead sheets almost never.

Cutting the end off is not the answer: the overflow usually comes from a misread earlier in the bar, so a cut drops
notes that were read right. A bar can overflow for several reasons, each with its own repair:

| Cause | Repair |
| --- | --- |
| Two lines that sound together (a melody over a held chord) written one after the other in one voice | split into two voices (no value changes) |
| A missed triplet (three eighths in a beat read plain) | make them a tuplet |
| One note's value or dot misread | the note's next most likely value |
| An extra note (a smudge, stem end or grace note read as a note) | drop it |
| A missed bar line (two bars read as one) | split the bar |
| A real meter change the reader missed | keep the new meter |

Plan:

1. **Keep the model's full choice lists.** The evidence model scores every choice for every head, but the reader
   keeps only the winner and its probability, except for onsets, tuplets and time. Keep the lists for note value
   (the class head), dots and voice too. Reader change only, no retraining.
2. **Search for the most believable reading that fits.** Every note's alternatives (value, dots, tuplet, voice)
   compete together, scored by the model's own probabilities, and the bar must come out exactly full. This is
   the rhythm decoder (`decodeRhythm`) with the bar length as a hard limit instead of a penalty, and with voice
   splits allowed. A fixed order of tries would miss combinations (a voice mix-up plus one wrong value); scoring
   does not. When every note was near certain, no value change is believable, which points to a voice split, an
   extra note or a missed bar line.
3. **Cut only as a last resort**, when no believable reading fits.

How to judge it: check bars and stretched bars (MuseScore's MIDI export, as for the tuplet fix) near zero with no
notes lost, on the whole test set. Then accuracy: the OpenScore pages come with the real scores, so check how often
the chosen repair is the right one, not just a tidy one.

## 1. Code: computer vision and rules (no model change)

| Issue | Seen in | Effect | Fix needed |
| --- | --- | --- | --- |
| Chords between the two staves of one system (melody over bass) dropped as "lyrics of the line above" | Roadside Distraction p. 2 (F, B♭, D♭, E♭ lost in 5 bars) | chords missing | Chord finder: its "text hangs below the line above" rule is meant for lyrics under the previous system; within one system, pass the words to the reader (lyrics do not parse as chords). Measure on piano-vocal pages, where lyrics do sit between staves. |
| A melody note high above the staff (with its accidental) looks like a second chord stacked under the real one, which is then dropped as "stacked" | Nacirema (E♭Δ9(♯11)/G♯, twice) | chord missing | Chord finder: clear accidentals and notes the detector placed on the staff before stacking words. Kept in step with `find.py`. |
| A chord printed across a bar line, centre just left of it, goes to the end of the earlier bar | Peaceful Warrior (B/F♯ bar 34 for 35) | chord a beat early | Needs a decision: ~130 such chords on real pages, no answer key for their bars. Jack to decide before any rule. |
| A missed bar line merges two bars into one | slash pages, synthetic sets (6 of 38 clean pages) | bar count off, endings and slashes wrong | Layout: find bar lines the detector missed (there is a pass for this; why these slip through is not yet looked at). |
| A multi-bar rest ("8" over a long rest) becomes one bar | Peaceful Warrior "Piano Interlude 8" | every later bar numbered wrong | Writer: read the number over a multi-rest and write that many bars. |
| Stemmed and half-note rhythm slashes stay notes | Secrets of the Stars bars 14, 42; Real Book bars with 6 slashes | wrong notes | Extend the slash finder to stems and hollow slashes; same aggregate checks as stemless slashes. |
| Small rhythm cues above the staff written as notes | Secrets of the Stars bars 43, 47 | extra notes | Writer or finder: notes far above the staff, smaller than the staff's noteheads, as cues. Not looked at. |
| Instruction sentences under notes read as lyrics | 4 of 37 Real Book pages | false lyrics | Lyric filter; text alone cannot tell them from lyrics. Possibly a "lyric line spans the system" test. |
| Lyrics on piano-vocal pages and on rough photos weaker | Jack's "Country Roads"; rough synthetic 73% vs clean 94% | missing and garbled syllables | Lyric finder band on piano-vocal pages; photo robustness. Two causes fixed in the working tree (Edelweiss, a user's Pianote PDF): a syllable spelled like a chord and hyphenated on ("E - del - weiss") was dropped, and the first word of a lyric line between the staves was also written as staff text. |
| A hymn's verse number ("1. Now") takes the first note, so the first word is lost and stays as staff text | "Now Let Us Rejoice" (secularhymnal.com) | first syllable of the verse missing | Lyric finder: a verse number is a label, the next word takes the note. Check on hymnals with numbered verses (the regression's hymns have none). |
| A staff missed on a clean page (nearly empty, or its lines broken up by ledger lines and 8va) | OpenScore: 23 of 79 pages | parts or systems grouped wrong, music on the wrong staff | Layout (CopistaFront staff tracing). The staff finder's threshold is load-bearing for faint lines: correcting it lost 9 OpenScore pages (Nov 19). |
| Large scores: a later page whose part names can't be read matches its staves to the wrong parts | The Matrix (a user's orchestral photocopy): 33 parts against about 25 | winds split into extra parts | CopistaMergeAlign; part names on photocopies' later pages are too small or faint to read. |
| One-line percussion staves not found | The Matrix | percussion missing | Staff finder looks for five lines only. |
| Part names read from page furniture on later pages | `scanned_regression_test` (a Japanese title read as the part name "民") | junk part name | Since 0.1.20 names are read on every page; a name should look like an instrument name or abbreviation. |
| Bass-only slash chords ("/A") read as A | Peaceful Warrior, Travelers | wrong root | Deferred by Jack. A slash-stroke check on the page was prototyped and removed. |

## 2. Chord reader retraining (RunPod)

The reader model itself misreads these; no text rule can repair them without guessing (e.g. "o7" is a real
diminished seventh). Data, hold-out sets and pass bars are in `NEXT_RUNPOD_RUN.md`.

| Issue | Seen in | Effect |
| --- | --- | --- |
| Plain "M" triad given a 7 (E♭M → EbM7) — new in round 4 | major/minor synthetic sheets (11 of 60) | wrong chord (major seventh) |
| Real Book handwritten G7 read as Gø7; ♯o7 read as a triangle — new in round 4 | Cheek to Cheek | wrong chord |
| min(omit3) garbled | Peaceful Warrior | wrong chord |

Fixed by round 4 (0.1.12): the MuseJazz triangle read as "o" or dropped, MuseJazz chords missed, madd9 as ma9, aug
as aug7, stacked 6/9 and m6/9, add9/add2/2 losing their number, sus2(add9). Numbers in the README ("Round 4").

13 and 13♯11 still come out as plain major chords in a third of bars (`--other` sheets, e.g. E♭13 bar 1 of sev019,
printed full size): the same with round 3 and 4, so it is not the reader. To look at in the finder or the writer,
with the crops drawn over the page.

## 3. Other models

| Issue | Seen in | Effect | Model |
| --- | --- | --- | --- |
| Handwritten "9/4" read as 4/4 (detector) and 6/4 (reader) | Peaceful Warrior bars 102-105 | wrong meter | copisteria detector and evidence reader |
| Time signature plus the first note's flat read as a key signature (a repeat bracket between clef and meter) | Travelers bass, bars 1-26 | wrong key, every A and E flat | copisteria detector |
| No slash or rhythm-slash class (handled in code for stemless slashes only) | all slash charts | see section 1 | copisteria detector (long term) |
| Boxed rehearsal letters in a handwriting font misread ("D" → "0") | Roadside Distraction | wrong rehearsal mark | text model (`text_rec.onnx`), a fine-tune of its own |
| Rehearsal letters H-L not found | Peaceful Warrior | rehearsal marks missing | partly the finder's box test, partly the text model |
| A plain note missed or misread, differently on the Mac and the phone (the page renders slightly differently) | Edelweiss: bar 30's bass G missed on the Mac, bar 25's bass dot lost on the phone | wrong or missing note | copisteria detector and evidence reader |

copisteria retraining is a larger job than the chord reader (detector and evidence models, its own training data);
collect cases here until it is worth it.

## 4. Jack's call before any change

| Question | Context |
| --- | --- |
| Does a bare "CΔ" mean Cmaj7 or C? | Now C, as the benchmark key reads it; many jazz books mean Cmaj7. One line to change. |
| Should part labels other than instrument names ("MELODY", "Lead") name the part? | Widening the rule risks tempo words at the top left ("Medium Swing"). A short list of label words (melody, lead, vocal, voice) is the safe middle. |
| What sound for a lone "Bass" part? | Today no instrument is written and MuseScore names it a bass voice. Bass clef suggests double bass or bass guitar. |
| Drop chords the grammar accepts only loosely ("F♯min(mi73)") instead of writing them garbled? | Small general rule; would also drop some real unusual chords. |
| Chords across bar lines (section 1) | see above |

## Fixed recently (for reference)

Not yet tagged (Nov 20): phone photos of curled book pages. Pages past 1 degree of tilt were left crooked, so the
staff finder lost bent systems and cut staves short. A page whose tilt changes by 3 degrees or more across it (a
curled photo) is now straightened in six strips across as well as in bands down (`Copista.curled`); flat scans
tilted evenly (Real Book pages at 1-2 degrees) stay untouched, since resampling them costs detections (a whole-bar
rest lost on Autumn in New York, a blank title staff found on Black Nile). With it: an opening line hidden by a
brace or the page-edge shadow is searched up to the later staff's start or first clef; three stems lined up
through every staff no longer make a bar line; a sliver under 3 staff spaces after the last bar line (courtesy
clef, key or meter) is not a bar. Regression vs 0.1.24: 843 identical, 14 changed, all phone photos and all
checked against the printed bar numbers: Oh Very Young 28 -> 30 (true 30), Freezing Steel 19 (unchanged bars),
Determination 36 -> 39, Spear of Justice 23 -> 28, Merry-Go-Round 34 -> 36, Sekai 39 -> 40, Date 34 -> 35, Lady
page 11 5 -> 4 bars (all now equal to the page); Itomori loses 2 of 33 chords. All open in MuseScore.

0.1.25 (Nov 20): a voice staff no longer splits off from its piano into a system of its own where three lyric lines
widen the gap and the photo is cropped tight or curls (a thin stroke that one staff's lines start at counts as the
system's opening line at a tight-cropped page edge, and between an untraced staff's box and its first clef). The
first songbook page reads 19 of 19 bars (was 22). Regression identical to 0.1.24.

0.1.24 (Nov 20): a hymn's verses stacked deeper than nine staff spaces are read (the third verse was lost, and its
words left as staff text on the next line); staff text that repeats a lyric line's words is dropped on every lyric
line, not only between a voice and its piano; "D7/4" (German hymnals) reads as D7sus4.

0.1.21 (Nov 19): a page whose last staff ends at its foot no longer crashes the scan (2 of 200 sampled Real Book
pages); chord-spelled syllables hyphenated on ("E - del - weiss") kept as lyrics;
lyric words between piano staves no longer also written as staff text; a new PDF page no longer restates its clefs,
key and meter, which Aria drew as a courtesy clef and meter before every page turn.

0.1.13-0.1.20: ScannerCore builds for Android; phone photos of books (page edge and binding shadow no longer join
piano systems, curled photos keep piano staves one part); a new PDF page starts a new system, not a new page;
incomplete tuplets kept without losing notes; MuseScore never refuses a scan (validity pass); runner-up values fit
overfull bars; notation on classical pages (ledger lines, pedal marks, "Op. 66") no longer read as chords, text or
lyrics; ordinary gaps printed as rests; large orchestral scores and photocopies (tilted pages straightened, staves
joined into systems by their bar lines, parts matched across pages by name and clef).

0.1.6-0.1.11: octave-clef misreads, italic chords as "pp", part names and instruments, slash bars (stemless),
1st/2nd endings, lyrics, DM as D major, sus2, madd9, 7+, +maj7, maj7sus, add♯11, triplet "3" as a chord, keys
changing only where printed, jazz-font triangle read as "a", boxed rehearsal letters, unreadable chords kept out of
staff text, top-left instrument label as part name.
