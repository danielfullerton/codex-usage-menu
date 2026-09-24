# Codex Usage Menu

Codex Usage Menu shows the percentage remaining in your weekly Codex limit in the macOS menu bar. It refreshes 30 seconds after each completed read. Open its dropdown to see the next weekly reset in your Mac's time zone and a live countdown to the next refresh. You can also refresh immediately or quit. Manual refresh restarts the countdown.

The app reads `account/rateLimits/read` from the local Codex app server. You must be signed in to Codex with your ChatGPT account. The app displays `—%` when it cannot read the weekly limit; open the dropdown for the error. It stores no account credentials or usage history.

## Build and run

Run `./build.sh`, then open `build/Codex Usage Menu.app`. The app requires macOS 15 or later, Xcode command-line tools, and a Codex CLI installation at `~/.local/bin/codex`, `/opt/homebrew/bin/codex`, or `/usr/local/bin/codex`.

The app runs only in the menu bar and does not add a Dock icon. It does not start at login.

## License

MIT. See [LICENSE](LICENSE).
