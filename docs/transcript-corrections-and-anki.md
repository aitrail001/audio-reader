# Transcript corrections and Anki export

AudioReader keeps imported EPUB text and speech-recognition output immutable. A
manual correction is stored as one overlay for one transcript sentence, so the
original can always be restored and a change can be synchronized without
rewriting the source transcript.

## Correct a transcript sentence

1. Open a chapter and choose **Edit transcript** for the sentence.
2. Edit the sentence text, its start time, its end time, or any combination of
   those fields.
3. Preview the corrected sentence against the local audio.
4. Choose **Save correction**. Choose **Restore original** to remove the
   current overlay and reveal the immutable source sentence.

A correction must still refer to the same source sentence fingerprint. Its text
cannot be empty, timing cannot be negative, the corrected sentence must last at
least 0.25 seconds, remain inside the chapter, and avoid overlapping either
neighbor. AudioReader retains a stale overlay for provenance after a transcript
is regenerated, but does not apply it to a different source fingerprint.

Corrections are sentence-level. They do not perform forced word alignment and
do not rewrite the original word timestamps. Playback, sentence looping,
lookup, assistant context, vocabulary capture, resume, and export all resolve
the same effective sentence text and bounds.

If two devices edit the same sentence from the same account revision,
AudioReader keeps the immutable source and one current correction, then asks
the reader to choose the correction to keep. It does not silently apply the
last write. A previously accepted translation for the old sentence stays in
local provenance, but is hidden until the corrected sentence is translated.

## Export vocabulary for Anki

In **Words**, select entries and choose **Export to Anki**. With no explicit
selection, AudioReader exports the current filtered result. The scope menu also
offers **Learning List** and **All Vocabulary**.

The exported ZIP contains:

- `notes.tsv`, a UTF-8 tab-separated note file;
- `manifest.json`, including counts and every audio omission;
- flat, deduplicated `.m4a` sentence clips referenced as
  `[sound:filename.m4a]` in the note file.

Each note includes the stable AudioReader ID, expression, resolved sentence,
gloss, book, author, chapter, timestamp, audio reference, and tags. Clips use
the corrected sentence bounds with 250 ms padding, clamped to the available
local media. Missing, protected, or unavailable audio creates a text-only note
and an omission in the manifest; it never uploads media or aborts the rest of
the export.

### Import into Anki Desktop

Anki imports text files and Anki deck packages, not AudioReader's transport ZIP
directly. This workflow intentionally remains TSV-based rather than `.apkg`:

1. Extract the ZIP.
2. With Anki closed, copy its `.m4a` files into the temporary profile's flat
   `collection.media` folder. Do not create a media subfolder.
3. In a fresh profile, create an `AudioReader` note type with these fields in
   order: **Stable ID**, **Expression**, **Sentence**, **Gloss**, **Book**,
   **Author**, **Chapter**, **Timestamp**, and **Audio**. The tenth TSV column
   is imported as Anki tags by the file's `#tags column:10` directive; it is
   not a separate note field. Add `{{Audio}}` to the card template so the clip
   is available during review.
4. Open Anki, choose **File → Import**, and select `notes.tsv`.
5. Select the `AudioReader` note type. Confirm tab separation and that columns
   1–9 map to the matching note fields while column 10 maps to **Tags**. Keep
   **Allow HTML in fields** enabled so sound references are recognized.
6. Import, open a card, and verify its field values and clip playback. Run
   **Tools → Check Media** before using the deck outside the temporary profile.

These steps follow the official Anki guidance for
[text imports](https://docs.ankiweb.net/importing/text-files.html) and
[media storage](https://docs.ankiweb.net/media.html). AudioReader does not
install an add-on, use AnkiConnect, or modify an existing Anki profile.
