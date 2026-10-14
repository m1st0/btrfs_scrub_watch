<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Maulik Mistry
SPDX-License-Identifier: Apache-2.0
-->
# btrfs_scrub_watch

A live terminal dashboard for following a Btrfs scrub that is running in 
another terminal. It shows progress, transfer rate, time left, error summary, 
and a countdown to the next update, then prints a summary when the scrub ends.

It is written in Zsh and operates as read-only: it only runs 
`btrfs scrub status`. It never starts, pauses, or cancels a scrub.

Copyright © 2026 Maulik Mistry

This project is licensed under Apache License 2.0. See the 
[LICENSE.txt](LICENSE.txt) file for details.

Please share support:
- [PayPal](https://www.paypal.com/paypalme/m1st0)
- [Venmo](https://venmo.com/code?user_id=3319592654995456106&created=1753283702)

## Features

- Animated spinner and a smooth progress bar with fractional block steps
- Shows status, start time, elapsed time, time left, ETA, rate, bytes scrubbed,
  and error summary
- Countdown bar to the next update, plus the time of the last check
- Redraws one complete frame per tick in the alternate screen, so output stays 
  in place and does not flicker
- Waits quietly if no scrub is running yet, then follows it once it starts
- Rings the terminal bell and prints a final summary when the scrub finishes, 
  aborts, or is interrupted
- Uses [gum](https://github.com/charmbracelet/gum) for the filesystem picker 
  and the final summary box when it is installed, and falls back to plain text 
  when it is not
- Falls back to ASCII drawing in non-UTF-8 locales and honors `NO_COLOR`
- Asks for your `sudo` password once at startup, never in the middle of the 
  dashboard

## Setup and Usage

Make the script executable and run it in a second terminal while the scrub runs
in the first:

  ```zsh
  chmod +x btrfs_scrub_watch.zsh
  sudo ./btrfs_scrub_watch.zsh -i 10 /media/external_drive
  ```

The path is the mount point of the Btrfs filesystem being scrubbed, the same 
one given to `btrfs scrub start`. It must be a mounted path such as `/` or 
`/mnt/data`, not a device such as `/dev/sdb1`.

If the script is run without a path, it detects mounted Btrfs filesystems. With
one, it uses it. With several, it offers a picker.

To start a scrub in the first terminal:

  ```zsh
  sudo btrfs scrub start /media/external_drive
  ```

## Options and Keys

| Option or key | Purpose |
| --- | --- |
| `-i SECONDS` | Seconds between `btrfs scrub status` queries. Default is `10`. |
| `-h` | Show usage. |
| `q` | Quit the dashboard. |
| `r` | Refresh now instead of waiting for the countdown. |


## Setting a Default Mount Point

To avoid typing the path each time, edit this line near the top of the script:

  ```zsh
  MNT=${1:-}
  ```

For example:

  ```zsh
  MNT=${1:-/media/external_drive}
  ```

A path given on the command line still overrides the default. If the default 
path contains spaces, quote it:

  ```zsh
  MNT="${1:-/media/my drive}"
  ```

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | The scrub finished with no errors found, or the dashboard was closed with `q`. |
| `1` | The scrub ended with errors, was aborted or interrupted, or a startup check failed. |
| `2` | Invalid options or interval. |
| `130` | Closed with Ctrl+C or a termination signal. |


## Requirements

- Zsh, including the `zsh/datetime` module
- `btrfs-progs`
- `sudo`, unless run as root
- `findmnt`, `stty`, `sed`, `head`, `sort`, and `sleep` from standard Linux 
  tools
- An interactive terminal
- Optional: [gum](https://github.com/charmbracelet/gum) for the picker and 
  summary box, or installed on Ubuntu with `sudo apt install gum` .
- Optional: a UTF-8 locale for the braille spinner and block progress bar

## Development Notes

This project was initially built with AI assistance from Claude.
