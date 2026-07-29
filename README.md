# Reminders → Calendar Bridge

A macOS menu-bar app that bridges Apple Reminders and Apple Calendar: it watches
the calendars of your choice in real time and writes, into the description of
each new session, the properties of the matching task and the cumulative time
already spent on the same work.

No polling: the app stays awake and subscribes to the system's
`EKEventStoreChanged` notification, emitted whenever the Calendar or Reminders
database changes — including when an event created on an iPhone finishes syncing
to the Mac.

The bundle identifier remains `fr.equiriconi.SessionsStats`, the name the app
carried at first. That identifier is what macOS ties the Calendar and Reminders
permissions to, along with the settings and the record of already processed
events. Changing it would reset all of them.

*Le README est également disponible en français : [README.fr.md](README.fr.md).*

## Installation

```
./build.sh
```

Then move `RemindersCalendarBridge.app` to `/Applications` and **launch it from
the Finder** (double-click). Once installed there, `build.sh` deploys later
builds to `/Applications` automatically.

Launching from the Finder is not cosmetic: started by another program, the app
inherits that program's permissions instead of requesting its own, and macOS
denies Calendar access without showing any dialog.

Two permission prompts appear on first launch (Calendar, then Reminders). Accept
both.

No Dock icon: the app lives in the menu bar.

## Settings

Menu bar → **Settings…**

**General**
- Watching enabled / launch at login
- Language (French, English, or follow the system)
- Detection window (±N days) and history depth (N years), shared by every pairing
- Permission status, tracked event count, last activity
- **Scan now**, **Forget state**, **Reprocess everything**
- Update checking

**Pairings** — see below.

**Log** — the last 200 lines, plus access to the full file.

## Pairings

A pairing links **one reminder list to one calendar**. There can be as many as
you like, each with its own formatting:

```
Doctorate - Tasks          →  Work sessions
Doctorate - Reading tasks  →  Reading sessions
```

The same calendar may appear in several pairings. An empty list ("None")
processes every event of the calendar and groups them on their own title,
without going through Reminders.

Each pairing defines:

- tolerance for a suffix after the task title;
- whether the task identifier is written into the notes, and the marker used for
  completed tasks;
- **the description sections, their order and their headers** — the order is
  changed by dragging rows;
- the initial text of the personal section;
- the contents of the statistics block, line by line;

with a live preview of the result.

## How it works

1. On each notification (coalesced over 2 s to absorb iCloud bursts), the events
   of every pairing are listed over the detection window.
2. They are compared against
   `~/Library/Application Support/RemindersCalendarBridge/state.json`, which
   holds what is known about each event. Detection therefore does not rely on
   creation dates: an event is "new" the moment it appears on the Mac, whatever
   the sync delay was.
3. Each event is attached to its task, then written if it is new or if the task
   has changed since the last pass.
4. Events belonging to the same task that end before the current session starts
   are counted, their durations summed, and the sections are written.

Title matching ignores case, accents and redundant whitespace.

## Dragging from Reminders

Dropping a reminder onto the calendar creates an event whose title is the task
title **followed by the contents of its notes**. The app handles this:

- matching is done by prefix, so the event is still attached to its task despite
  the suffix ("Allow a suffix after the task title");
- grouping is done on the **task** title, otherwise the same activity would be
  counted separately depending on whether the suffix is present;
- the event title is reduced to the task title as it appears in Reminders;
- the notes content is not salvaged from the title: it is rebuilt cleanly from
  the reminder's own properties, in the "Task information" section below.

**First run**: existing events are recorded as seen without being modified — the
history is not rewritten retroactively. The "Reprocess everything" button forces
the opposite.

## Event description

It is made of three marked sections:

```
── Task information ──
List: Doctorate - Tasks
Due: September 14, 2026
Priority: high
Notes: see the July 3 minutes

── Personal notes ──
Reread interviews 4 to 7, outline of section 2 settled.

── Statistics ──
Session #8 — “Writing chapter 2”
This session: 2 h 30
Earlier sessions: 7 — 14 h 15
Last session: July 22, 2026
Total: 16 h 45
```

**Task information** — read from the reminder itself: list, due date, start
date, priority, location, link, recurrence, alerts, completion date, notes. Only
the properties that are set appear. Regenerated on every pass.

**Personal notes** — a protected section. Its contents are carried over
verbatim, including through a full reprocess: this is where to write what you
accomplished. Free text found in a description that predates any section is
moved here on the first pass rather than being overwritten.

**Statistics** — regenerated on every pass.

The order of the three sections is set by dragging, pairing by pairing, and each
section can be disabled. The section headers are customisable: changing them
afterwards prevents already written sections from being found in existing
events.

## Following modified tasks

Every written event carries a link to its reminder in the **Location or Video
Call** field:

```
x-apple-reminderkit://REMCDReminder/5C1F…A93
```

Calendar renders it as a clickable link, so the task opens in Reminders in one
click — and the same field doubles as a durable identifier.

That link is what makes tracking possible. Rename a reminder, or change its due
date, priority or notes, and every event that depends on it is updated on the
next pass — title included. Title comparison alone could not do this: after a
rename, nothing would match any more.

Statistics are never lost in the process: they are not stored, they are
recomputed from the calendar on every write. Personal notes are carried over
verbatim.

A location you typed yourself is never overwritten: the field is written only
when it is empty or already holds a reminder link.

Attachment is resolved in this order: link in the location, identifier written
at the end of the notes (optional, off by default, useful if you keep the
location field for an actual place), local state file, then title comparison.

**Completed task** — as soon as a reminder is ticked, the title of its events is
prefixed with a marker (`✅` by default, customisable or removable per pairing).
Unticking the task removes it.

## Language

French and English, chosen in the General tab, or following the system language.
The setting applies to the interface as well as to the text written into event
descriptions.

## Updates

The app queries this repository's GitHub releases, at most once a day, and
reports when a newer version exists. Nothing is installed without your consent.

Because the app is ad-hoc signed, there is no developer certificate to verify.
The trust model therefore rests on three points: the repository is pinned in the
code, the exchange happens over HTTPS, and the downloaded archive must carry an
intact signature and the same bundle identifier as the installed app. The
previous version is kept during the swap and restored if anything fails.

To publish a version: set the new number in `CFBundleShortVersionString`
(Info.plist), build, then

```
ditto -c -k --sequesterRsrc --keepParent /Applications/RemindersCalendarBridge.app RemindersCalendarBridge.zip
gh release create vX.Y.Z RemindersCalendarBridge.zip --title vX.Y.Z --notes "…"
```

## Signing and permissions

`build.sh` signs the app ad-hoc, which is enough for TCC and for launch at
login. Every rebuild changes the binary's hash, so macOS may ask for permissions
again.

**Critical point**: signing enables the hardened runtime, and in that mode macOS
requires explicit entitlements to reach Calendar and Reminders. They are
declared in `RemindersCalendarBridge.entitlements`:

- `com.apple.security.personal-information.calendars`
- `com.apple.security.personal-information.reminders`

Without them, access is denied **immediately and silently**: no permission
dialog appears, the app shows up nowhere in System Settings → Privacy, and
nothing in its own log explains why. The diagnosis is only readable in `tccd`'s
traces:

```
/usr/bin/log stream --predicate 'process == "tccd"' --info --debug
```

Do not remove the `--entitlements` option from `build.sh`.

## Licence

MIT — see [LICENSE](LICENSE).
