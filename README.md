# Mango Wrapper

Just a [mango](https://github.com/mangowm/mango) IPC wrapper I've written to
implement the features I want (to the fullest extent possible) without
bothering the maintainer.

It's for my own personal use, so use it at your own risk.

Currently the feature set is as follows:

- `[view/tag]to[left/right]` and `viewto[left/right]_have_client` wrap around
- Toggle between the current and previous layouts of the currently selected tag

# Building

## Debug build

```sh
./build.sh debug
```

## Release build

```sh
./build.sh release
```
