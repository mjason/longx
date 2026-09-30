# Native shell surfaces

This is the page/native-client contract for menus and popups that should use
platform UI rather than React DOM. The TypeScript source of truth is
`assets/js/ui/shell/longxShell.ts`; the page integration points are the
command palette, keyboard picker and prompt, project job chip, scheduled-watch
chip, and workbench tab context menu.

## Opt in and compatibility

The page announces bridge `version: 2` in its `ready` message. A client that
implements native surfaces opts in after the page installs its bridge:

```js
window.LongxShell?.setCapabilities(["surfaces"]);
```

Until the client opts in, the web app keeps rendering its existing React
dialogs and popovers. Older clients therefore do not receive an unknown
message and do not suppress the web UI. Native UI should be enabled only when
the client can answer every `surface` request.

Messages are JSON. Android receives them through `LongxAndroid.post(json)`;
iOS receives them through `webkit.messageHandlers.longx.postMessage(json)`.
The client presents the requested native view, then completes it by calling
`window.LongxShell.surfaceResult(id, value)` in the WebView. Always complete a
request, including when the person dismisses it (`value: null`), so the page
can finish its pending interaction. IDs are opaque and correlate concurrent
requests; do not synthesize or reuse them.

```json
{
  "type": "surface",
  "id": "surface-12",
  "surface": "picker",
  "title": "切换标签",
  "placement": "bottom",
  "data": { "items": [] }
}
```

`placement` is a hint: `bottom` for a bottom sheet / bottom-anchored native
panel, `center` for the quick command palette, and `anchor` for a context menu.
For `anchor`, `data.point` contains viewport-relative `{ "x": number,
"y": number }` coordinates. Native clients may adapt placement for their
platform (for example, a macOS popover with a material/blurred background).

## Surface kinds

| `surface` | Purpose | Request `data` | Return through `surfaceResult` |
| --- | --- | --- | --- |
| `menu` | Quick command palette or a tab's right-click menu | `items` for the palette, or `actions` and optional `point` for a tab menu | Palette: `{ "id": "thread:slug:id" }`, `"project:slug"`, `"command:command.id"`, `"action:new"`, or `"action:settings"`. Tab menu: `{ "action": "activate" }` or `{ "action": "close" }`. |
| `picker` | A fixed list picker requested by keyboard commands | `placeholder`, `items` | Item ID as a string or `{ "id": "…" }`. |
| `prompt` | A text entry requested by a keyboard command | `label`, initial `value`, `submit` button label | Submitted text as a string or `{ "value": "…" }`. |
| `tasks` | Running Longx-managed shell jobs in this project | `projectId`, `slug`, `jobs` | Dismiss with `null`; open a job with `LongxShell.navigate("/p/<slug>/t/<threadId>")`. |
| `watches` | Enabled scheduled watches in this project | `projectId`, `slug`, `rootPath`, `watches` | Dismiss with `null`; the settings page is `/p/<slug>/settings`. |

The palette's `data.searchable` is `true`; filter its supplied `items` locally
as the person types. Each item has a stable `id`, display `label`, and may have
`group`, `detail`, `shortcut`, or `status` (`waiting` / `running`). The palette
item IDs are routing/action tokens, not database IDs by themselves.

Picker items are the `PickerItem` fields in
`assets/js/core/keys/picker.ts`: `id`, `label`, and optional `detail`, `note`,
`hint`, `tone`, `current`, `group`, and `keywords`. Only fixed-list pickers
are native today; the asynchronous file search picker stays in the web UI.

Prompt input should start with the supplied value, submit the trimmed text,
and use `null` for cancel. The page trims and validates again before invoking
the command's callback.

Each job contains `name`, `cmd`, `status`, `exitCode`, `reason`, `startedAt`,
`finishedAt`, `threadId`, and `threadTitle`. Each watch sent to the native
surface contains only `id`, `name`, `path`, `kind`, `cron`, `at`,
`nextDueAt`, `runningSince`, `lastRunAt`, `lastDurationMs`, and `lastError`.
The watch's `webhookToken` and internal `state` are deliberately not sent.

## Native-side implementation checklist

1. Wait until `window.LongxShell` exists and inspect `version`. Enable the
   `surfaces` capability only for version 2+ clients that implement this
   contract.
2. Handle `type: "surface"` on the existing Android/iOS message channel. Keep
   the view native (menus, sheets, text input and task cards); do not inject
   HTML to imitate the platform controls.
3. Render according to `surface` and `placement`; preserve the item's IDs and
   action strings exactly.
4. Return one result with the original request ID when selected/submitted, or
   `null` when cancelled. For task rows, navigate through
   `LongxShell.navigate` rather than opening a second web view.
5. If an unsupported surface is received, do not opt in globally; leave that
   surface to the web renderer.

The web app remains the source of business state and action execution. The
native client owns presentation, filtering for the searchable palette, text
entry, and returning the selected action.
