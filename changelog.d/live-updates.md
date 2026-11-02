### Added
- Phone: optional **Live updates**. With your own push server (`server/`, see its README), Toggl
  webhooks reach the phone through Firebase Cloud Messaging, so a timer stopped or started on
  another device shows on the watch within seconds. While they work, the phone polls Toggl once a
  day instead of every 15 minutes, and opening the watch app or tile no longer calls Toggl.
