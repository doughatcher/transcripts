# App Store artwork

The purple/black cards use native captures from invented meeting data.

1. `just shots` rebuilds the Mac app in staging and renders guide screenshots.
2. `just store-shots` captures iPhone and iPad using temporary simulators.
3. `node scripts/store-artwork/render.cjs` composes all three families into `dist/store-artwork/`. It needs the `playwright` Node package and Microsoft Edge. Set `NODE_PATH` if Playwright is provided by an external runtime.
4. Inspect the exported images, then run `just store-upload --dir dist/store-artwork` against editable drafts.

The website uses the plain images in `docs/guide/images`, not these cards. The Mac template clips the native menu and overlay captures into drawn desktop context; it uses no retouched UI text. Keep its clip coordinates in sync if the native capture dimensions change.
