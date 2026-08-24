# StashCount

World of Warcraft addon that shows, right in the item tooltip, how many of that
item you have stashed across your account:

- Per character, split into bags vs. personal bank
- In the shared Warband Bank
- A grand total

## Why

Useful for anyone who crafts/stockpiles items (potions, mats, etc.) spread
across multiple characters and the Warband Bank, and wants a quick "how many
do I actually have" at a glance without opening every character/bank.

## How it works

- Item counts are cached per-character in account-wide `SavedVariables`
  (`StashCountDB`), refreshed automatically as bags/bank change.
- Bank and Warband Bank contents are only readable while their UI is open, so
  those are refreshed on bank visits (per tab) and reused from cache
  otherwise.
- The tooltip shows the oldest cached data timestamp at the bottom, so you
  know if a number might be stale (e.g. a character you haven't logged in
  for a while).

## Install

Copy (or symlink) this folder into:

```
World of Warcraft/_retail_/Interface/AddOns/StashCount
```

## Commands

- `/sc` — list tracked characters and last-update times
- `/sc scan` — force a rescan (bags always; bank/Warband only if the bank is
  currently open)

## Status

Actively in development — built and tested iteratively in-game.
