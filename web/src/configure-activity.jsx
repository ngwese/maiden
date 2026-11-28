import React, { Component } from 'react';
import cx from 'classname';
import { VERSION, COMMIT } from './version';
import api from './api';

import './configure-activity.css';

class ConfigureActivity extends Component {
  constructor(props) {
    super(props);

    this.state = {
      style: {
        height: props.height,
        width: props.width,
      },
      editorConfig: { ...this.props.editorOptions },
    };

    props.editorConfig(api.editorConfigResource());
  }

  componentDidMount() {
    this.props.onRef(this);
  }

  componentWillUnmount() {
    this.props.onRef(undefined);
  }

  updateConfiguration(key, val) {
    this.setState({
      editorConfig: { ...this.state.editorConfig, [key]: val },
    });
  }

  save() {
    this.props.updateEditorConfig(api.editorConfigResource(), this.state.editorConfig);
  }

  renderEditorOption(key, val, label) {
    const editorOptionClasses = (key, val) => {
      if (val) {
        return cx('configure-option', { 'is-selected': this.state.editorConfig[key] === val });
      }
      return cx('configure-option', { 'is-selected': !this.state.editorConfig[key] });
    };

    return (
      <button
        className={editorOptionClasses(key, val)}
        onClick={() => this.updateConfiguration(key, val)}
      >
        {label}
      </button>
    );
  }

  render() {
    return (
      <div className="configure-activity" style={this.state.style}>
        <div className="configure-upper">
          <div className="configure-header">editor options</div>
          <div className="configure-item">
            <div className="configure-label">key bindings:</div>
            <div className="configure-options">
              {this.renderEditorOption('keyBoardHandler', null, 'default')}
              {this.renderEditorOption('keyBoardHandler', 'ace/keyboard/vim', 'vim')}
              {this.renderEditorOption('keyBoardHandler', 'ace/keyboard/emacs', 'emacs')}
            </div>
          </div>
          <div className="configure-item">
            <div className="configure-label">tab size:</div>
            <div className="configure-options">
              {this.renderEditorOption('tabSize', 2, 'two')}
              {this.renderEditorOption('tabSize', 4, 'four')}
            </div>
          </div>
          <div className="configure-item">
            <div className="configure-label">editor theme:</div>
            <div className="configure-options">
              {this.renderEditorOption('editorTheme', 'light', 'light')}
              {this.renderEditorOption('editorTheme', 'dark', 'dark')}
            </div>
          </div>
          <div className="configure-item">
            <div className="configure-label">minimap:</div>
            <div className="configure-options">
              {this.renderEditorOption('minimap', false, 'off')}
              {this.renderEditorOption('minimap', true, 'on')}
            </div>
          </div>
          <div className="configure-header">explorer</div>
          <div className="configure-item">
            <div className="configure-label">auto hide sections:</div>
            <div className="configure-options">
              {this.renderEditorOption('autoHideSections', false, 'off')}
              {this.renderEditorOption('autoHideSections', true, 'on')}
            </div>
          </div>
        </div>
        <div className="configure-lower">
          <div className="configure-about">
            <span>
              maiden version: {VERSION} ({COMMIT})
            </span>
          </div>
        </div>
      </div>
    );
  }
}

export default ConfigureActivity;
