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

This direction is strictly read-only. Plex is never modified by the sync, and no
Slack reactions are posted as a result of it.

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
the part that identifies it. **The video's folder and file are then renamed on
disk** — a database-only title would look right in the menu bar and wrong on the
television, which is the screen that matters.

```
Pizza_Bean_Mr_Bean_Cartoon_Season_2_Full_Episodes_Mr_Bean_Official [exampleVid1]/
                              ↓
Pizza Bean [exampleVid1]/
  Pizza Bean [exampleVid1].webm
  poster.jpg
```

The `[exampleVid1]` suffix is never touched. Everything that finds a video again
looks for that ID rather than the name — Plex matching, the ❌ reaction, the
re-sync — so the title is the only part that's actually free to change.

**Playlists are context.** Someone browsing "Mr Bean Cartoon" can already see
whose cartoon it is, so joining that playlist re-runs the cleanup with the
playlist name in hand and the show name drops out of the title. Removing the
reaction runs it again with what's left. Every cleanup starts from the name
yt-dlp originally chose rather than from the previous cleaned title, so guesswork
never compounds and taking off the last reaction lands exactly where it started.

Each answer is cached per `(video, playlist context)`, so reacting, un-reacting
and re-reacting costs one API call, not three.

Every row also has a ✨ button to do this by hand, which turns into an undo once
the title has been changed. Undo puts the original yt-dlp name back on disk.

Nothing here runs without an API key — a blank key means the feature is simply
off, not broken. **Plex shows the new title after its next library scan**, since
it reads titles from the folder name.

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
  Some Show S01E04 [exampleVid1]/
    Some Show S01E04 [exampleVid1].webm
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
wrote them.

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
| `PlexSync` | Periodic read of view stats and playlist membership |
| `PlaylistSync` | Reactions → playlist membership |
| `LibraryPruner` | The disk limit |
| `TitleCleaner` | Title cleanup: the prompt, the rename, the undo |
| `ClaudeClient` | The Claude API call behind it |
| `EmojiNames` | Generated shortcode ↔ emoji table |
| `SingleInstance` | The lock |
