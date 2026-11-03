<h1 align="center">nanomcp</h1>

<p align="center">An MCP gateway with a window: the MCP servers behind one endpoint, the tools they offer as one list, and who is using them — drawn with <a href="https://github.com/justrach/nanoui"><strong>nanoui</strong></a>.</p>

<p align="center">
  <img alt="macOS · Linux · Windows" src="https://img.shields.io/badge/macOS%20·%20Linux%20·%20Windows-555">
  <img alt="Zero dependencies" src="https://img.shields.io/badge/dependencies-0-44cc11">
  <img alt="Built in Zig 0.17" src="https://img.shields.io/badge/built%20in-Zig%200.17-f7a41d?logo=zig&logoColor=white">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

A rewrite of [mcp-go](https://gitee.com/sternelee/mcp-go) on nanoui: same
behaviour, same words, same tests, one window instead of a terminal. The Go
original remains the reference; `DESIGN.zh.md` maps every Go file to the Zig
file that replaced it, and says why.

## What it does

- **One endpoint for many servers.** The gateway speaks MCP over stdio, the
  older SSE transport, and streamable HTTP, and serves whatever is behind it
  as a single tool list, each tool named after the server it came from.
- **Servers it can reach.** A command (stdio), or a URL over SSE or HTTP,
  with headers, a token, or a sign-in.
- **Signing in upstream.** OAuth 2.1 with PKCE and dynamic client
  registration, per server, with the token stored for the next time.
- **Callers.** The gateway can be open, ask for a token of its own, or be an
  OAuth 2.1 authorization server itself, issuing tokens to the clients that
  call it, with a consent page and a token lifetime.
- **The market.** Search a registry, read a package, install it into the
  configuration in one step.
- **Pasting a configuration.** The `mcpServers` block other MCP clients
  write can be pasted in as it stands, in any of the shapes they use.
- **Five pages and a menu bar.** Servers, the market, the routes (who is
  connected and what they called), the tools, and settings; a bolt beside
  the clock whose menu opens the window on either of the two pages a gateway
  is looked at through, and whose title counts the connected agents.

## Get started

```sh
cd nanomcp
zig build run --fork=../..     # build against the nanoui in this repository
```

`--fork=../..` is Zig's own flag: it uses the nanoui sources beside this app
instead of the pinned release in `build.zig.zon`. Inside a checkout of this
repository that is what you want; without it, the pinned release is used.

```sh
zig build --fork=../..                                   # macOS
zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux --fork=../..   # Linux
zig build -Dtarget=x86_64-windows-gnu --fork=../..       # Windows
```

## Tests

The Go original's tests are ported test for test, in the form nanoui's tests
take: a `test "a sentence describing the behaviour"` beside the code it
describes, and the ones that need a UI driven by `ui.Tester` offscreen.

```sh
zig build test --fork=../..          # every test, the UI included
zig test src/config.zig              # one module, without the toolkit
```

Nothing in the suite opens a window, touches the clipboard, or writes outside
its own temporary directory.

## Where it keeps things

| What | Where |
| --- | --- |
| Servers and settings | `$HOME/.local/share/nanomcp/userdata/servers.json` |
| Tokens and client credentials | the same directory, one file per server, mode 0600 |
| Somewhere else for a test run | `NANOMCP_TEST_DIR=/tmp/…` |
| The gateway itself | `127.0.0.1:7331` by default |

## Headless

The window never has to be shown to look at it:

```sh
zig-out/bin/nanomcp --nanoui-snapshot=/tmp/nanomcp.png
zig-out/bin/nanomcp --nanoui-eval='…'
```

Both imply `--nanoui-hidden`, which also leaves the menu bar alone.

## Layout

`src/` holds one file per concern: `gateway.zig` (the gateway and its
request lifecycle), `mcp_endpoint.zig`, `transport_{stdio,sse,http}.zig`
(the three faces), `upstream.zig` (a connected server), `oauth.zig` and
`tokens.zig` (the authorization server and its tokens), `auth.zig`,
`sessions.zig` (who is calling), `registry.zig` (the market), `config.zig`,
`credentials.zig`, `import.zig`, `menubar.zig`, `page_*.zig` (the five
pages), `view.zig`, `state.zig`. `DESIGN.zh.md` is the full specification,
written from a reading of the Go original before this was written.

## Licence

MIT, as the Go original. The licence texts of what it links against are kept
verbatim in the repository's `third_party/licenses/`.
