# Interface validation

Test the complete app in portrait and landscape. Use both an empty library
and imported games with short names, long names, custom artwork, and no artwork.

## Library

- Add a folder, confirm the executable, select its cover, and play.
- Keep All Games and Favorites labels stable. Show search advice only for an
  active search with no results.
- Open and exit search with the keyboard visible.
- Check the first and last covers and rapid direction changes. The selected
  cover must align with the title without duplicating games.
- Keep the library fixed vertically. Check cover and focus-outline clearance.
- Verify that custom names, artwork, crops, and match removal survive relaunch.

## Menus and input

- Open Game Options and Settings repeatedly. Record the transitions to detect
  title clipping or a position change before the final frame.
- Test touch, D-pad, left stick, keyboard arrows, Select, and Back/Escape.
- Confirm that only the visible menu receives input.
- Test connect, disconnect, and reconnect during menu navigation and gameplay.
- Show generic controller hints after controller input and hide them on touch.
- Check mouse motion and buttons on the physical device; menu focus does not
  establish that mouse events reach a game.

## Player

- Check launch progress and performance controls clear the safe areas.
- Open and dismiss the menu repeatedly, including taps outside the game image.
- Confirm Close Game and verify return to the library after shutdown.
- Check rendering, audio, input, and saves separately.

## Appearance and accessibility

- Use native Apple controls, system type, and consistent surfaces.
- Check normal, selected, and disabled text contrast over light and dark artwork.
- Test Dynamic Type, VoiceOver, Reduce Motion, and Reduce Transparency.
- Keep titles, buttons, focus outlines, and scrolling content clear of cuts.
- Keep content visible without waiting for an animation to finish.

Record the build, device or simulator, steps, observations, and untested paths.
A preview or successful build does not establish full-app or physical-input
behavior. Follow the [release policy](../docs/releasing.md) for release evidence.
