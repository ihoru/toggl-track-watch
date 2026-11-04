### Added
- Phone: optional **Live updates**, turned on with one tap. The phone sets up a Toggl webhook to the
  Track Watch server (or your own, `server/`), which forwards changes through Firebase Cloud
  Messaging, so a timer stopped or started on another device shows on the watch within seconds.
  While they work, the phone polls Toggl once a day instead of every 15 minutes, and opening the
  watch app or tile no longer calls Toggl.
