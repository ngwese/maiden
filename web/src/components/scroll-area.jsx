import React, { Component } from 'react';
import cx from 'classname';
import { ensurePanelGestureGuard } from '../panel-gesture-guard';
import './scroll-area.css';

const HIDE_DELAY_MS = 500;

// Overlay scrollbar styled after Monaco/VS Code:
// thin translucent thumb, auto-hides when idle, fades back in on scroll/hover.
class ScrollArea extends Component {
  constructor(props) {
    super(props);
    this.state = {
      visible: false,
      fading: false,
      scrollable: false,
      thumbHeight: 0,
      thumbTop: 0,
      thumbActive: false,
    };
    this.hideTimer = null;
  }

  componentDidMount() {
    ensurePanelGestureGuard();
    this.observe();
    this.updateThumb();
  }

  componentWillUnmount() {
    this.clearHideTimer();
    this.endThumbDrag();
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.mutationObserver) {
      this.mutationObserver.disconnect();
    }
  }

  observe = () => {
    if (typeof ResizeObserver !== 'undefined') {
      if (!this.resizeObserver) {
        this.resizeObserver = new ResizeObserver(() => this.updateThumb());
      }
      if (this.viewport) {
        this.resizeObserver.observe(this.viewport);
      }
      if (this.content) {
        this.resizeObserver.observe(this.content);
      }
    }
    if (typeof MutationObserver !== 'undefined' && this.viewport && !this.mutationObserver) {
      this.mutationObserver = new MutationObserver(() => this.updateThumb());
      this.mutationObserver.observe(this.viewport, {
        childList: true,
        subtree: true,
        characterData: true,
      });
    }
  };

  setViewportRef = (elem) => {
    this.viewport = elem;
    if (elem) {
      this.observe();
    }
    if (this.props.viewportRef) {
      this.props.viewportRef(elem);
    }
  };

  setContentRef = (elem) => {
    this.content = elem;
    if (elem) {
      this.observe();
    }
  };

  clearHideTimer = () => {
    if (this.hideTimer !== null) {
      window.clearTimeout(this.hideTimer);
      this.hideTimer = null;
    }
  };

  scheduleHide = () => {
    this.clearHideTimer();
    if (this.state.thumbActive || this.pointerInside) {
      return;
    }
    this.hideTimer = window.setTimeout(() => {
      this.hideTimer = null;
      this.setState({ visible: false, fading: true });
    }, HIDE_DELAY_MS);
  };

  reveal = () => {
    if (!this.state.scrollable) {
      return;
    }
    this.clearHideTimer();
    this.setState({ visible: true, fading: false });
    this.scheduleHide();
  };

  updateThumb = () => {
    const viewport = this.viewport;
    if (!viewport) {
      return;
    }

    const { clientHeight, scrollHeight, scrollTop } = viewport;
    const scrollable = scrollHeight > clientHeight + 1;
    let thumbHeight = 0;
    let thumbTop = 0;

    if (scrollable && clientHeight > 0) {
      thumbHeight = Math.max(20, Math.round((clientHeight / scrollHeight) * clientHeight));
      const maxTop = clientHeight - thumbHeight;
      const maxScroll = scrollHeight - clientHeight;
      thumbTop = maxScroll > 0 ? Math.round((scrollTop / maxScroll) * maxTop) : 0;
    }

    const next = { scrollable, thumbHeight, thumbTop };
    const changed =
      this.state.scrollable !== scrollable ||
      this.state.thumbHeight !== thumbHeight ||
      this.state.thumbTop !== thumbTop;

    if (changed) {
      this.setState(next, () => {
        if (!scrollable && (this.state.visible || this.state.fading)) {
          this.setState({ visible: false, fading: false });
        }
      });
    }
  };

  onScroll = () => {
    this.updateThumb();
    this.reveal();
    if (this.props.onScroll) {
      this.props.onScroll(this.viewport);
    }
  };

  onPointerEnter = () => {
    this.pointerInside = true;
    this.reveal();
  };

  onPointerLeave = () => {
    this.pointerInside = false;
    this.scheduleHide();
  };

  onRailPointerDown = (event) => {
    if (event.target !== this.rail || !this.viewport) {
      return;
    }
    event.preventDefault();
    const rect = this.rail.getBoundingClientRect();
    const y = event.clientY - rect.top;
    const { clientHeight, scrollHeight } = this.viewport;
    const thumbHeight = this.state.thumbHeight;
    const maxTop = clientHeight - thumbHeight;
    const nextTop = Math.min(maxTop, Math.max(0, y - thumbHeight / 2));
    const maxScroll = scrollHeight - clientHeight;
    this.viewport.scrollTop = maxScroll > 0 ? (nextTop / maxTop) * maxScroll : 0;
    this.reveal();
  };

  onThumbPointerDown = (event) => {
    if (!this.viewport) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();

    const startY = event.clientY;
    const startScrollTop = this.viewport.scrollTop;
    const { clientHeight, scrollHeight } = this.viewport;
    const maxScroll = scrollHeight - clientHeight;
    const maxTop = clientHeight - this.state.thumbHeight;
    const scrollPerPixel = maxTop > 0 ? maxScroll / maxTop : 0;
    const target = event.currentTarget;

    // Keep pointer events on the thumb so leaving left/right does not hit
    // panel separators or other resize handles.
    if (target && target.setPointerCapture) {
      target.setPointerCapture(event.pointerId);
      this.capturedThumb = target;
      this.capturedPointerId = event.pointerId;
    }

    this.setState({ thumbActive: true, visible: true, fading: false });
    this.clearHideTimer();

    this.thumbMove = (moveEvent) => {
      moveEvent.preventDefault();
      moveEvent.stopPropagation();
      const delta = moveEvent.clientY - startY;
      this.viewport.scrollTop = Math.min(
        maxScroll,
        Math.max(0, startScrollTop + delta * scrollPerPixel),
      );
    };

    this.thumbUp = (upEvent) => {
      if (upEvent) {
        upEvent.preventDefault();
        upEvent.stopPropagation();
      }
      this.endThumbDrag();
      this.setState({ thumbActive: false });
      this.scheduleHide();
    };

    window.addEventListener('pointermove', this.thumbMove, true);
    window.addEventListener('pointerup', this.thumbUp, true);
    window.addEventListener('pointercancel', this.thumbUp, true);
  };

  endThumbDrag = () => {
    if (this.capturedThumb && this.capturedPointerId != null) {
      try {
        this.capturedThumb.releasePointerCapture(this.capturedPointerId);
      } catch (err) {
        // Pointer may already have been released.
      }
      this.capturedThumb = null;
      this.capturedPointerId = null;
    }
    if (this.thumbMove) {
      window.removeEventListener('pointermove', this.thumbMove, true);
      this.thumbMove = null;
    }
    if (this.thumbUp) {
      window.removeEventListener('pointerup', this.thumbUp, true);
      window.removeEventListener('pointercancel', this.thumbUp, true);
      this.thumbUp = null;
    }
  };

  render() {
    const { className, style, children } = this.props;
    const { visible, fading, scrollable, thumbHeight, thumbTop, thumbActive } = this.state;
    const showRail = scrollable && (visible || fading);

    return (
      <div
        className={cx('scroll-area', className)}
        style={style}
        onPointerEnter={this.onPointerEnter}
        onPointerLeave={this.onPointerLeave}
      >
        <div className="scroll-area-viewport" ref={this.setViewportRef} onScroll={this.onScroll}>
          <div className="scroll-area-content" ref={this.setContentRef}>
            {children}
          </div>
        </div>
        {showRail ? (
          <div
            className={cx('scroll-area-rail', {
              'is-visible': visible,
              'is-fading': fading && !visible,
            })}
            data-panel-gesture-block
            ref={(elem) => (this.rail = elem)}
            onPointerDown={this.onRailPointerDown}
          >
            <div
              className={cx('scroll-area-thumb', { 'is-active': thumbActive })}
              data-panel-gesture-block
              style={{ height: thumbHeight, top: thumbTop }}
              onPointerDown={this.onThumbPointerDown}
            />
          </div>
        ) : null}
      </div>
    );
  }
}

export default ScrollArea;
