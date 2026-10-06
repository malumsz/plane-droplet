<div align="center">

<img src="Assets/icon.png" alt="Plane Tasks" width="88" height="88">
<img src="https://gitlab.com/droppyformac1/droplets/-/raw/main/assets/droplet-store.png" alt="Droppy" width="88" height="88">

 <h1>Plane Tasks</h1>

A [Droppy](https://getdroppy.app) droplet that keeps your [Plane](https://plane.so) work items on the shelf.

<p>
  <img alt="Version" src="https://shieldcn.dev/badge/version-1.1.0.svg?variant=outline&size=sm&logo=ri:LuTag">
  <img alt="DroppyKit" src="https://shieldcn.dev/badge/DroppyKit-1.20.1.svg?variant=outline&size=sm&logo=ri:LuPackage">
  <a href="LICENSE"><img alt="License" src="https://shieldcn.dev/badge/license-MIT.svg?variant=outline&size=sm&logo=ri:LuScale"></a>
</p>

[Features](#features) · [Install](#install) · [Set up](#set-up) · [Security](#security) · [Changelog](CHANGELOG.md)

</div>

<br>

<div align="center">
<img width="265" height="auto" alt="Droppy_2026-10-03-22-52-23_E767DA-ezgif com-video-to-gif-converter" src="https://github.com/user-attachments/assets/4118a9f5-b54f-4a52-8431-0c8fbd0d3d4f" />
<img width="283" height="auto" alt="Droppy_2026-10-03-22-44-05_8F9D8F-ezgif com-video-to-gif-converter" src="https://github.com/user-attachments/assets/ab7a096a-a03c-40ef-b735-d45562ca5574" />
</div>

---

### Features

- **Assigned work items** from every project you can access in your workspace, newest first.
- **Pinned tab** for the tasks you want to keep in view, regardless of project or status.
- **Filters and search** with status chips and counts, a project menu, and search by title, ID or project.
- **Task details** with state, priority, dates and project, plus the description rendered with its formatting: headings, lists, checklists, tables, code and links.
- **New task alerts** beside the notch.
- **Compact widget** that shows your pinned tasks.
- **Open in Plane** from any task.

### Requirements

- macOS 15 or later
- Droppy 15.3 or later, or [Droppy Playground](https://getdroppy.app/download/playground)
- A Plane account and a ``Personal Access Token``

### Install

```bash
git clone https://github.com/malumsz/plane-droplet.git
cd plane-droplet
droppykit build      # writes .build/PlaneTasks.droplet
```

This needs the [DroppyKit command line tool](https://getdroppy.app/docs/droppykit).

Droppy runs an unsigned droplet once you approve the build under **Settings → Store → Local droplets**. Droppy Playground loads unsigned droplets without asking.

### Set up

1. In Plane, open **Profile settings → Personal Access Tokens** and create a token.
2. In Droppy, open this droplet's settings and fill in:

   | Field | Value |
   | --- | --- |
   | Workspace slug | The slug from `https://app.plane.so/<workspace-slug>/` |
   | Personal access token | The token you created |
   | Plane API URL | Only for self-hosted Plane. Plane Cloud uses `https://api.plane.so` |

3. Press **Refresh**.

### Security

- The token is stored in the macOS Keychain.
- The droplet only talks to the API URL you configure. It must use `https`.
- The workspace slug may only contain letters, numbers, `-` and `_`.
- Workspace slug, API URL, pinned tasks and notification settings live in Droppy's isolated preferences for this droplet.

### License

[MIT](LICENSE) © [malumsz](https://github.com/malumsz)

---
