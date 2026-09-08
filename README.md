# Kid Video Thing

**THIS IS SLOP. This program is vibe coded. Whatever it says down there might not be accurate. The thing might not work.**

A macOS menu bar app that turns "someone posted a YouTube link in Slack" into
"the kids can watch it in Plex, offline, without an algorithm attached."

Drop a link in a Slack channel. The app downloads it, gives it Plex-shaped cover
art, files it into a library, and keeps that library tidy. React with an emoji to
sort it into a Plex playlist. React with ❌ to delete it.

## Goals

- **Curation over feed.** Videos land in a library someone chose, not a
  recommendation engine. The kids browse a shelf; the adults decide what's on it.
- **Slack is the remote control.** Adding a video should be as easy as pasting a
  link where the family already talks. No app to open, no form to fill in.
- **Plex is the television.** Whatever the app produces has to look native in
  Plex — poster art, one folder per video, sensible titles.
- **Bounded and self-tending.** The library has a disk ceiling and drops what
  nobody watches, so it never needs manual cleanup.
- **Nothing to babysit.** It lives in the menu bar with no Dock icon, reconnects
  on its own, survives restarts, and refuses to run twice.

## The three places

```
   SLACK                      APP                        PLEX
   (input)                (the record)               (authority)

  message ──────────────▶ videos table ◀───────────── playlists
  reactions ────────────▶  + files on disk ◀────────── watch history
      ▲                        │                          ▲
      └──── 👀 ✅ ⚠️ ❌ ────────┘                          │
                               └──── add/remove ──────────┘
                                     playlist items
```

Each place owns something different, and the app never argues with the others
about it:

| Place | Owns |
|---|---|
| **Slack** | What was requested, and by whom. Reactions are input, not state. |
| **The app** | The record: which video, which file, how big, where it came from — and what it's called. |
| **Plex** | What's been watched, and what's in which playlist. |

## Flow 1 — Slack to the app: getting a video

1. Someone posts a YouTube link. A **bare link** counts as a request; a link
   mentioned mid-sentence doesn't, unless the bot is @mentioned.
2. The app reacts 👀 and queues it.
3. A **playlist link** is expanded first (`yt-dlp --flat-playlist`), so each video
   in it gets its own row, file, and poster. The playlist URL itself is never
   stored as a video.
4. `yt-dlp` downloads into `~/Media/Kid Video Thing/<Title> [videoID]/`.
5. The YouTube thumbnail is fetched and composed onto a 1000×1500 black canvas —
   Plex wants a 2:3 poster, and letterboxing a 16:9 frame beats cropping it.
   Saved as `poster.jpg` beside the video.
6. 👀 is replaced with ✅, or ⚠️ if yt-dlp failed.

**The link between a Slack message and a video file is the database row**, keyed
on `(channel, message_ts, url)`. Without it, a reaction arriving days later would
have nothing to act on.

## Flow 2 — Plex to the app: what's been watched

Every 15 minutes (configurable), and whenever the menu bar panel is opened, the
app reads the local Plex server at `localhost:32400`:

- **View counts and last-viewed dates** land on each row and show in the list.
- **Playlist membership** becomes the emoji badges on each row.

Videos are matched to Plex items by the **YouTube ID in the filename** — Plex
reports each item's file path, and `… [exampleVid1].webm` identifies it more
durably than a path that might change.

No Slack reactions are posted as a result of this. Everything Plex is the
authority on is read-only — the app never edits a view count or a playlist here.
The sync does finish by pushing the two things *we* decide, titles and which
poster to use, back the other way; see Flow 6.

## Flow 3 — the app back to Slack: status

The app writes exactly four reactions, and only these:

| | Meaning |
|---|---|
| 👀 | Downloading right now |
| ✅ | On disk |
| ⚠️ | Download failed |
| ❌ | Deleted — by request, or by the disk limit |

Everything else on a message belongs to whoever put it there. The app never adds
or removes a playlist emoji, because Slack won't let it remove a person's
reaction and a half-removable badge is worse than none.

## Flow 4 — Slack to Plex: playlists

Name a Plex playlist with an emoji — `Dinosaurs 🦕` — and that emoji claims it.

- React 🦕 on a message → its videos join every playlist with 🦕 in the name.
- Remove the reaction → they're taken out again.
- React on a **playlist link** → all of its videos are filed at once.

Slack sends reactions as shortcodes (`sauropod`) while Plex titles contain
characters (🦕), and nothing in the event carries a codepoint. `EmojiNames.swift`
is a generated table of ~1,900 Slack shortcodes that bridges the two.

👀 ✅ ⚠️ ❌ are reserved and can't claim a playlist.

## Flow 5 — deletion and the disk limit

Two ways a video leaves:

- **❌ on the message** deletes its folder, poster included, and marks the row
  deleted so it's never re-downloaded by a sync.
- **The disk limit** (default 50 GB) is checked after every download. If the
  library is over, videos are deleted **from the bottom of the list** — never
  watched first, oldest first — until it fits. A message gets ❌ only once *none*
  of its videos survive, so a playlist losing one episode isn't mislabelled.

The video that just downloaded is never evicted; otherwise you'd watch it vanish.

## Flow 6 — titles: from keyword soup to something readable

YouTube titles are written to be found, not to be read. "Pizza Bean Mr Bean
Cartoon Season 2 Full Episodes Mr Bean Official" is the "Pizza Bean" episode with
the search terms bolted on, and that's what ends up on the shelf in Plex.

When a video arrives, its title goes to the Claude API and comes back cut down to
the part that identifies it. **Nothing on disk changes.** The title is kept in the
videos table and pushed to Plex, which is the only place it needs to be right.

```
on disk (never touched)   the record        Plex
Arcade_Trouble_Mr_Bean_…  title =           title  = "Arcade Trouble"  (locked)
  [Ih76cnYuEoY].webm      "Arcade Trouble"  poster = poster.jpg        (locked)
poster.jpg
```

Renaming the files was tried first and worked, but it meant moving a video out
from under Plex every time a title changed, leaving Plex to work out what it was
looking at all over again. The filename is now the one name nobody edits, which
makes it a dependable place to start from: every cleanup works from what yt-dlp
chose, so guesswork never compounds and undo always has somewhere to land.

**Both fields are locked in Plex, and that's the point.** An unlocked field is one
Plex treats as its own to work out — it re-derives the title from the filename and
re-picks the artwork whenever it refreshes an item. That is how a library ends up
showing video stills instead of the posters sitting right beside the files.
Locking is what makes a title or a poster stay put.

**Playlists are context.** Someone browsing "Mr Bean Cartoon" can already see whose
cartoon it is, so joining that playlist re-runs the cleanup with the playlist name
in hand and the show name drops out of the title. Removing the reaction runs it
again with what's left. Each answer is cached per `(video, playlist context)`, so
reacting, un-reacting and re-reacting costs one API call, not three.

Every row also has a ✨ button to do this by hand, which turns into an undo once
the title has been changed. Undo drops our title and hands the field back to Plex
unlocked, so Plex goes back to reading the filename — exactly where it started.

Pushing to Plex is retried rather than done once: a video can appear in Plex long
after it was downloaded, so every sync brings the two back into line. Nothing here
runs without an API key — a blank key means the feature is simply off, not broken.

## Reconciliation

Reality drifts: the app is closed when a link is posted, a file is moved by hand,
a download is interrupted. **Settings → Slack → Re-sync State** walks 30 days of
history and repairs what it can, deliberately conservatively:

- 👀 with no outcome → the download was interrupted; restart it.
- ⚠️ → retry it.
- ✅ but the file is gone → find it by video ID; if it's really gone, mark ❌.
- **No record at all → do nothing.** An empty database means we know nothing, not
  that nothing happened. Assuming otherwise once stripped ✅ off a whole channel.

It also backfills anything added later — missing posters, file sizes, per-video
folders — and re-reads playlists, since a playlist can gain videos at any time.

## On disk

```
~/Media/Kid Video Thing/
  Some_Show_S01E04 [exampleVid1]/
    Some_Show_S01E04 [exampleVid1].webm
    poster.jpg

~/Library/Application Support/kid-video-thing/
  videos.sqlite      one row per (message, video)
  instance.lock      flock'd; only one copy runs
```

One folder per video, because Plex treats a folder as one movie — a shared
`poster.jpg` in a flat directory would claim every file in it.

## Setup

**Requires** `yt-dlp` (`brew install yt-dlp`), plus `ffmpeg` for merging formats,
and a Plex server on the same Mac.

**Slack app** — enable Socket Mode, then:

- Bot scopes: `channels:history`, `groups:history`, `channels:read`,
  `groups:read`, `reactions:read`, `reactions:write`, `chat:write`
- Bot events: `message.channels`, `message.groups`, `reaction_added`,
  `reaction_removed`
- Invite the bot to the channel, and paste both tokens into Settings → Slack

**Claude** — paste an API key from console.anthropic.com into Settings → Claude
to switch on title cleanup. Haiku is the default model; a whole library's worth of
titles costs a fraction of a cent. Leave it blank and titles are left as yt-dlp
wrote them. Titles are pushed to Plex, so this needs the Plex side working too.

**Plex** — the token is read automatically from the local install. The library
needs the Local Media Assets agent enabled and "Use local assets" turned on, or
the posters are ignored.

## Layout

| File | Role |
|---|---|
| `SlackListener` | Socket Mode connection, events, reconciliation |
| `SlackClient` | The handful of Slack Web API calls used |
| `DownloadManager` | Queue, one yt-dlp at a time, database bookkeeping |
| `YTDLP` | Locating and running the binary |
| `VideoStore` | SQLite; the record |
| `Library` | What the list shows — rows merged from the database and the queue |
| `MediaLayout` | Folder-per-video layout, migration, deletion |
| `CoverArt` | Thumbnail fetch and poster composition |
| `PlexClient` | Plex HTTP API |
| `PlexSync` | Periodic read of view stats and playlist membership; pushes titles and posters back |
| `PlaylistSync` | Reactions → playlist membership |
| `LibraryPruner` | The disk limit |
| `TitleCleaner` | Title cleanup: the prompt, the record, the push to Plex |
| `ClaudeClient` | The Claude API call behind it |
| `EmojiNames` | Generated shortcode ↔ emoji table |
| `SingleInstance` | The lock |
| `Tools/MakeIcon.swift` | Draws the app icon from the menu bar's SF Symbol — `make icon` |
