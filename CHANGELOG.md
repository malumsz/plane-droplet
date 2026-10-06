# Changelog

## [1.1.0] - 2026-10-03

### Added

- Pinned tab: pin tasks with the pin button on a task and see them in one
  place, independent of project and status.
- Filters: status chips with task counts, a project menu and search by title,
  ID and project.
- Task details panel with state, priority, start date, due date and project.
- Rich description rendering: headings, lists, checklists, tables, code and
  links.
- New task alerts beside the notch, with a badge on the All tab, a
  configurable check interval (1 to 30 minutes) and alert duration (3 to 15
  seconds).
- Compact widget layout that shows the pinned tasks and their details when the
  widget is paired with another one.
- Scroll fade on the task list, and a settings pane with workspace, token and
  API URL fields and a connection status.
- Creator information and icon in the droplet manifest.
- MIT license.

### Changed

- Requires DroppyKit 1.20.1 or later.
- Visual refresh of the list and details screens in native macOS style.

### Fixed

- Compact widget cards were cut off in narrow layouts.
- Project access issue when loading tasks.
- Localization and settings pane leftovers removed.

### Security

- The Plane API URL must use `https`; `http` is only accepted for
  `localhost`, `127.0.0.1` and `::1`, so the token is not sent unencrypted to
  other hosts.
- The workspace slug is validated (letters, numbers, `-` and `_`) before it is
  used in a request path.
- Saving the token to the Keychain now reports failures instead of ignoring
  them, and the item is only readable while the Mac is unlocked.
- Local build backups and machine-specific agent configuration are no longer
  tracked in the repository.

## [1.0.0] - 2026-09-25

- First release.
- Shows open Plane work items assigned to the person behind the configured
  Personal Access Token.
