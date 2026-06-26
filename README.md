# DockMover

Move the iPad dock anywhere on screen.

A SpringBoard tweak for **rootful iOS 14** iPad (tested on iPad6,3 / iOS 14.8.1,
checkra1n/palera1n + libhooker). On iPad the visible dock is the floating-dock
platter (`SBFloatingDockPlatterView`); DockMover lets you drag it around and
remembers where you put it.

## Usage

On the dock:

| Gesture | Action |
| --- | --- |
| **Two-finger drag** | Move the dock anywhere on screen (position is saved) |
| **Two-finger triple-tap** | Reset the dock to its default position |

Single-finger touches are untouched, so launching apps and context menus work
as normal.

## How it works

SpringBoard re-centers the dock platter on every layout pass and stomps any
`transform` you set on it. So instead of fighting it, DockMover re-applies the
saved offset to the platter at the **end** of the container's `-layoutSubviews`,
after `%orig` has placed it at its base position. Because the offset is always
measured from the freshly-computed base, it is stable and never compounds.

The offset is persisted in `com.mikey820.dockmover` (`offX` / `offY`).

## Building

Built on GitHub Actions (`macos-latest` + theos, iOS 14.5 SDK, rootful).
Push to `master` or run the workflow manually; the `.deb` is uploaded as a
build artifact.

```
make package FINALPACKAGE=1
```

Install over SSH:

```
dpkg -i com.mikey820.dockmover_1.0.0_iphoneos-arm.deb
killall -9 SpringBoard
```
