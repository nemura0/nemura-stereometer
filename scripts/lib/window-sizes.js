// Prints the on-screen windows of one process as JSON: [{"width", "height", "layer"}], in points.
//
//   osascript -l JavaScript scripts/lib/window-sizes.js <pid>
//
// Window bounds come from CGWindowListCopyWindowInfo, which needs no permission (window titles
// would need Screen Recording, so they are not read).
ObjC.import('CoreGraphics');

function run(argv) {
  const pid = parseInt(argv[0], 10);
  const options = $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements;
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(options, $.kCGNullWindowID));
  const windows = [];
  for (let i = 0; i < list.count; i++) {
    const info = list.objectAtIndex(i);
    if (ObjC.unwrap(info.objectForKey('kCGWindowOwnerPID')) !== pid) continue;
    const bounds = ObjC.deepUnwrap(info.objectForKey('kCGWindowBounds'));
    windows.push({
      width: bounds.Width,
      height: bounds.Height,
      layer: ObjC.unwrap(info.objectForKey('kCGWindowLayer')),
    });
  }
  return JSON.stringify(windows);
}
