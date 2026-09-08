// Defense in depth. Native WebKit delegates enforce navigation and download policy.
// This is injected into every frame in an isolated content world.
(() => {
  for (const name of ['contextmenu', 'dragstart', 'drop', 'gesturestart', 'gesturechange']) {
    document.addEventListener(name, event => event.preventDefault(), { capture: true, passive: false });
  }
  document.addEventListener('wheel', event => {
    if (event.ctrlKey || event.metaKey) event.preventDefault();
  }, { capture: true, passive: false });
  document.addEventListener('click', event => {
    if (event.target.closest?.('a[download]')) event.preventDefault();
  }, true);
})();
