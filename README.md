# Plane Tasks

A Droppy shelf widget that shows open Plane work items assigned to the user
behind a Personal Access Token.

## Set up

1. In Plane, open **Profile settings → Personal Access Tokens** and create a
   token.
2. In Droppy, open this droplet's settings and enter the workspace slug from
   `https://app.plane.so/<workspace-slug>/` and the token.
3. Press **Refresh**. The shelf lists the first three open assignments; each
   row opens that item in Plane.

The token is stored in the macOS Keychain under `app.getdroppy.plane-tasks`.
The workspace slug and optional API URL are stored in Droppy's isolated
preferences. Plane Cloud uses `https://api.plane.so`; change the API URL only
for a self-hosted Plane instance.

A Droplet for [Droppy](https://getdroppy.app), built with
[DroppyKit](https://getdroppy.app/docs/droppykit).

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce PlaneTasks.droplet
droppykit validate   # the checks the Store repository runs
droppykit submit     # open the merge request that puts it in the Store
```

## With a coding agent

Open this folder in Claude Code, Codex or Cursor. `AGENTS.md` is the brief
they read first, and `.mcp.json` / `.cursor/mcp.json` connect the DroppyKit
MCP server, which gives them the build, the checks, pictures of every surface
and an install into Droppy Playground as tools. Codex registers the server
once per Mac: `codex mcp add droppykit -- path/to/droppykit/Scripts/droppykit mcp`.
Run `droppykit agent` again after moving this folder or the SDK checkout.

## Before submitting

- Replace `PlaneTasks.icon` with real artwork, in Icon Composer.
- Replace `Assets/Creator.png` with your own square, unrounded mark.
- Fill in `summary`, `description` and `creator` in `droplet.json`, and
  write `CHANGELOG.md`.
- `droppykit submit`: the Store is a repository, one folder per droplet, and
  this opens the merge request that adds yours. See
  [Submitting](https://getdroppy.app/docs/droppykit/submitting).
