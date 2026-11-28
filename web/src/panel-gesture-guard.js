// react-resizable-panels listens for pointerdown on document in the capture
// phase and expands separator hit targets into neighboring panels. Clicks on
// overlay controls that sit in that hit zone (explorer scroll thumbs, section
// resize handles) must preventDefault on window capture—before the library's
// document listener—so the splitter does not activate. See fi() which bails
// when event.defaultPrevented is set.

const BLOCK_SELECTOR = '[data-panel-gesture-block]';

let installed = false;

const onPointerDownCapture = (event) => {
  const target = event.target;
  if (target && typeof target.closest === 'function' && target.closest(BLOCK_SELECTOR)) {
    event.preventDefault();
  }
};

export const ensurePanelGestureGuard = () => {
  if (installed || typeof window === 'undefined') {
    return;
  }
  installed = true;
  window.addEventListener('pointerdown', onPointerDownCapture, true);
};
