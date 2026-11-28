import React, { Component } from 'react';
import linkifyText from './linkify-text';
import ScrollArea from './components/scroll-area';
import './repl.css';

class ReplOutput extends Component {
  constructor(props) {
    super(props);
    this.scrollAdjusted = false;
  }

  componentDidUpdate() {
    // FIXME: this always forces scrolling to the bottom
    if (this.output) {
      this.output.scrollTop = this.output.scrollHeight;
    }
  }

  isScrolledBottom() {
    if (!this.output) {
      return false;
    }
    const top = this.output.scrollTop;
    const totalHeight = this.output.offsetHeight;
    const clientHeight = this.output.clientHeight;
    const atBottom = totalHeight <= top + clientHeight;
    console.log('top', top, 'totalH', totalHeight, 'clientH', clientHeight, 'bottom', atBottom);
    return atBottom;
  }

  render() {
    const lines = this.props.lines.map((l, key) => (
      <div className="repl-line" key={key}>
        {linkifyText(l)}
      </div>
    ));

    // this.isScrolledBottom()
    return (
      <ScrollArea className="repl-output" viewportRef={(elem) => (this.output = elem)}>
        {lines}
      </ScrollArea>
    );
  }
}

class ReplInput extends Component {
  constructor(props) {
    super(props);
    this.historyIdx = 0;
  }

  onKeyDown = (event) => {
    let history;

    switch (event.keyCode) {
      case 13: // return
        event.preventDefault();
        this.props.sendCommand(this.input.value);
        this.input.value = '';
        this.historyIdx = 0;
        break;

      case 38: // up arrow
        event.preventDefault();
        history = this.props.history;
        if (this.historyIdx < history.size) {
          this.input.value = history.get(this.historyIdx);
          this.historyIdx += 1;
        }
        break;

      case 40: // down arrow
        event.preventDefault();
        this.historyIdx -= 1;
        if (this.historyIdx < 0) {
          this.historyIdx = 0;
          this.input.value = '';
        } else {
          this.input.value = this.props.history.get(this.historyIdx);
        }
        break;

      default:
        break;
    }
  };

  componentDidMount() {
    this.input.focus();
  }

  render() {
    return (
      <div className="repl-input">
        <span className="label">&gt;&gt;</span>
        <textarea
          className="value"
          ref={(e) => {
            this.input = e;
          }}
          onKeyDown={this.onKeyDown}
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          autoComplete="off"
          rows={1}
        />
      </div>
    );
  }
}

class Repl extends Component {
  sendCommand = (text) => {
    this.props.replSend(this.props.activeRepl, text);
  };

  render() {
    let lines = this.props.buffers.get(this.props.activeRepl);
    if (lines === undefined) {
      lines = [];
    }
    const history = this.props.history.get(this.props.activeRepl);
    const style = {
      height: this.props.height,
      width: this.props.width,
    };

    let content;
    if (this.props.renderChild) {
      content = this.props.children;
    } else {
      content = <ReplOutput lines={lines} />;
    }

    return (
      <div className="repl" style={style}>
        {content}
        <ReplInput sendCommand={this.sendCommand} history={history} />
      </div>
    );
  }
}

export default Repl;
