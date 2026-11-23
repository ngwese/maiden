import React, { Component } from 'react';
import SplitPane from 'react-split-pane';
import ReactAudioPlayer from 'react-audio-player';
import { ImpulseSpinner } from 'react-spinners-kit';
import Explorer from './explorer';
import Editor from './editor';
import ToolBar from './tool-bar';
import IconButton from './icon-button';
import ModalContent from './modal-content';
import { ICONS } from './svg-icons';
import { commandService } from './services';
import OS from './utils';
import { bufferIsEditable, bufferIsAudio } from './model/edit-helpers';
import ReplActivity from './bound-repl-activity';

import './edit-activity.css';

const STALE_BANNER_HEIGHT = 32;

const resourceBasename = resource => {
  if (!resource) {
    return '';
  }
  const parts = String(resource).split('/').filter(Boolean);
  return parts[parts.length - 1] || resource;
};

const tools = [
  {
    name: 'save',
    tooltipMessage: `save script (${OS.metaKey()}S)`,
    tooltipPosition: 'left',
    icon: ICONS['floppy-disk'],
    disabled: false,
  },
  {
    name: 'play',
    tooltipMessage: `run script (${OS.metaKey()}P)`,
    tooltipPosition: 'left',
    icon: ICONS.play3,
    disabled: false,
  },
  {
    name: 'stop',
    tooltipMessage: `stop script (${OS.metaKey()}.)`,
    tooltipPosition: 'left',
    icon: ICONS.stop,
    disable: false,
    alwaysEnable: true,
  },
];

const EditTools = props => {
  const items = props.tools.map(tool => (
    <IconButton
      tooltipMessage={tool.tooltipMessage}
      tooltipPosition={tool.tooltipPosition}
      key={tool.name}
      action={() => props.buttonAction(tool.name)}
      icon={tool.icon}
      color="hsl(0, 0%, 59%)"
      size="24" // FIXME:
      disabled={tool.disabled}
    />
  ));

  const style = { width: props.width, height: props.height };
  return <ToolBar style={style}>{items}</ToolBar>;
};

class EditActivity extends Component {
  constructor(props) {
    super(props);
    this.state = {
      toolbarWidth: 50,
      sidebarWidth: props.ui.sidebarWidth,
      replHeight: props.ui.replHeight,
    };
  }

  componentWillReceiveProps(newProps) {
    // if the active buffer is dirty grab it out of the child prior to a potential re-render so that the current buffer state isn't lost
    const { activeBuffer, buffers } = this.props;
    const newActiveBuffer = newProps.activeBuffer;
    if (activeBuffer !== newActiveBuffer && buffers.has(activeBuffer)) {
      if (this.editor) {
        this.props.bufferChange(activeBuffer, this.editor.getValue());
      }
    }

    const newBuffers = newProps.buffers;
    if (newActiveBuffer && !newBuffers.has(newActiveBuffer)) {
      // active buffer isn't (yet) loaded, trigger read
      this.props.bufferRead(newActiveBuffer);
    } else if (
      newActiveBuffer &&
      newActiveBuffer !== activeBuffer &&
      newBuffers.has(newActiveBuffer)
    ) {
      // switching back to an already-buffered file; check device mtime
      this.props.bufferCheckStale(newActiveBuffer);
    }
  }

  sidebarSplitSizing() {
    return {
      size: this.props.ui.sidebarHidden ? 1 : this.state.sidebarWidth,
      minSize: this.props.ui.sidebarMinWidth,
      defaultSize: this.props.ui.sidebarWidth,
      maxSize: this.props.ui.sidebarMaxWidth,
    };
  }

  getSidebarWidth() {
    return this.props.ui.sidebarHidden ? 1 : this.state.sidebarWidth;
  }

  replSplitSizing() {
    return {
      size: this.props.ui.replHidden ? 0 : this.state.replHeight,
      minSize: this.props.ui.replMinHeight,
      defaultSize: this.props.ui.replMinHeight,
      maxSize: this.props.height - this.props.ui.editorMinHeight,
    };
  }

  getEditorHeight() {
    return this.props.ui.replHidden
      ? this.props.height
      : this.props.height - this.state.replHeight - 1;
  }

  showStaleBanner(buffer) {
    return Boolean(buffer && buffer.get('stale') && !buffer.get('staleDismissed'));
  }

  editorSize(bannerVisible) {
    const sidebarWidth = this.getSidebarWidth();
    const toolbarWidth = this.state.toolbarWidth;
    const width = this.props.width - sidebarWidth - toolbarWidth - 1;
    const height = this.getEditorHeight() - (bannerVisible ? STALE_BANNER_HEIGHT : 0);
    return {
      width,
      height,
    };
  }

  editorToolsSize(bannerVisible) {
    return {
      width: this.state.toolbarWidth,
      height: this.getEditorHeight() - (bannerVisible ? STALE_BANNER_HEIGHT : 0),
    };
  }

  replSize() {
    return {
      width: this.props.width - this.getSidebarWidth(),
      height: this.state.replHeight,
    };
  }

  handleSidebarSplitChange = size => {
    if (size <= this.props.ui.sidebarMinWidth && this.props.ui.sidebarHidden) {
      // it is hidden so allow resize to reveal
      this.props.sidebarToggle();
    }
    this.setState({
      sidebarWidth: size,
    });
  };

  handleSidebarSplitDragFinish = () => {
    this.props.sidebarSize(this.state.sidebarWidth);
  };

  handleReplSplitChange = size => {
    this.setState({
      replHeight: size,
    });
  };

  handleReplSplitDragFinish = () => {
    this.props.replSize(this.state.replHeight);
  };

  getActiveBuffer = () => this.props.buffers.get(this.props.activeBuffer);

  saveActiveBuffer = (afterSave, options = {}) => {
    const resource = this.props.activeBuffer;
    const value = this.editor.getValue();
    this.editor.bufferWillSave(resource);
    this.props.bufferSave(
      resource,
      value,
      result => {
        if (result && result.conflict) {
          const name = resourceBasename(resource);
          this.props.showModal(
            <ModalContent
              message="File changed on device. Overwrite?"
              supporting={name}
              buttonAction={choice => {
                this.props.hideModal();
                if (choice === 'ok') {
                  this.saveActiveBuffer(afterSave, { force: true });
                }
              }}
            />,
          );
          return;
        }
        if (result && result.ok) {
          this.editor.bufferWasSaved(resource);
          if (afterSave) {
            afterSave();
          }
        }
      },
      options,
    );
  };

  handleStaleRefresh = () => {
    const resource = this.props.activeBuffer;
    if (resource) {
      this.props.bufferRead(resource);
    }
  };

  handleStaleDismiss = () => {
    const resource = this.props.activeBuffer;
    if (resource) {
      this.props.bufferDismissStale(resource);
    }
  };

  handleToolInvoke = tool => {
    const buffer = this.getActiveBuffer();
    const resource = this.props.activeBuffer; // FIXME: this assumes the activeBuffer is a URL

    if (tool === 'stop') {
      this.props.scriptClear();
      return;
    }

    // remaining tools require a buffer
    if (!buffer) {
      return;
    }

    if (tool === 'save') {
      if (buffer.get('modified')) {
        this.saveActiveBuffer();
      } else {
        // Clean buffer: HEAD and surface the refresh banner if the device copy moved on.
        this.props.bufferCheckStale(resource);
      }
    } else if (tool === 'play') {
      if (buffer.get('modified')) {
        // Dirty buffer: conditional PUT, then run.
        this.saveActiveBuffer(() => {
          this.props.scriptRun(resource);
        });
      } else {
        // Clean buffer: don't run a device script that differs from the editor view.
        Promise.resolve(this.props.bufferCheckStale(resource)).then(stale => {
          if (!stale) {
            this.props.scriptRun(resource);
          }
        });
      }
    } else {
      // fallthrough behavior
      this.props.toolInvoke(tool);
    }
  };

  handleResourceRename = (resource, name, virtual) => {
    // MAINT: this annoying; rename changes names, urls, and active this/that which in turn causes a re-render. if the script being renamed is "virtual" then the editor buffer might contain changes which haven't been sync'd to the store. trigger a sync to ensure those changes aren't lost by the rename
    if (virtual) {
      console.log('syncing editor before rename just in case...');
      this.props.bufferChange(this.props.activeBuffer, this.editor.getValue());
    }
    this.props.explorerResourceRename(resource, name, virtual);
  };

  isText = buffer => buffer && bufferIsEditable(buffer);

  isAudio = buffer => buffer && bufferIsAudio(buffer);

  render() {
    const activeBuffer = this.props.activeBuffer;
    const buffer = this.getActiveBuffer();

    const canEdit = this.isText(buffer);
    const code = canEdit ? buffer.get('value') : '';

    const canListen = this.isAudio(buffer);

    const enabledTools = tools.map(t => ({ ...t, disabled: !(canEdit || t.alwaysEnable) }));

    // TODO (pq): move this somewhere more appropriate.
    commandService.registerCommand('toggle repl', () => this.props.replToggle());
    commandService.registerCommand('toggle sidebar', () => this.props.sidebarToggle());
    commandService.registerCommand('play', () => this.handleToolInvoke('play'));
    commandService.registerCommand('save', () => this.handleToolInvoke('save'));
    commandService.registerCommand('stop', () => this.handleToolInvoke('stop'));

    const bannerVisible = this.showStaleBanner(buffer);
    const staleBanner = bannerVisible ? (
      <div className="stale-banner" style={{ height: STALE_BANNER_HEIGHT }}>
        <span className="stale-banner-message">File changed on device since it was loaded</span>
        <button type="button" className="stale-banner-action" onClick={this.handleStaleRefresh}>
          Refresh
        </button>
        <button type="button" className="stale-banner-action" onClick={this.handleStaleDismiss}>
          Dismiss
        </button>
      </div>
    ) : null;

    // TODO: switch editor based on buffer content type
    const editor = (
      <div className="editor-pane-wrap">
        {staleBanner}
        <div className="editor-pane">
          <Editor
            className="editor-container"
            ref={component => {
              this.editor = component;
            }}
            {...this.editorSize(bannerVisible)}
            bufferName={activeBuffer}
            toolInvoke={this.handleToolInvoke}
            editorOptions={this.props.editorOptions}
            sidebarToggle={this.props.sidebarToggle}
            value={code}
            bufferChange={this.props.bufferChange}
            editorConfig={this.props.editorConfig}
            selectionEval={this.props.selectionEval}
          />
          <EditTools
            className="edit-tools"
            {...this.editorToolsSize(bannerVisible)}
            tools={enabledTools}
            buttonAction={this.handleToolInvoke}
          />
        </div>
      </div>
    );

    const listener = (
      <div className="listener-pane">
        <ReactAudioPlayer className="listener-container" src={activeBuffer} autoPlay controls />
      </div>
    );

    const loading = (
      <div className="spinner-pane">
        <ImpulseSpinner frontColor="#979797" backColor="#F1F1F1" loading />
      </div>
    );

    const landing = (
      <div className="landing-pane">
        <span className="message">new script</span>
        <IconButton
          action={() => this.props.editorScriptNew()}
          tooltipMessage="new script"
          tooltipPosition="bottom"
          icon={ICONS.plus}
          color="hsl(0, 0%, 59%)"
          size="24"
        />
      </div>
    );

    const sidebarSplitStyle = {
      height: this.props.height,
      width: this.props.width,
      position: 'relative', // must be inline to override library behavior
    };

    const explorerStyle = {
      height: this.props.height,
    };

    // MAINT: this is ugly, ideally there would be states in the model which
    // correspond to each pane and the whole component refactored
    let element = loading;
    if (buffer) {
      element = canListen ? listener : editor;
    } else if (!activeBuffer) {
      element = landing;
    }

    return (
      <SplitPane
        split="vertical"
        style={sidebarSplitStyle}
        {...this.sidebarSplitSizing()}
        onChange={this.handleSidebarSplitChange}
        onDragFinished={this.handleSidebarSplitDragFinish}
        paneClassName="editor-pane-common"
      >
        <Explorer
          className="explorer-container"
          hidden={this.props.ui.sidebarHidden}
          style={explorerStyle}
          data={this.props.explorerData}
          bufferSelect={this.props.bufferSelect}
          directoryRead={this.props.directoryRead}
          directoryCreate={this.props.explorerDirectoryCreate}
          scriptCreate={this.props.explorerScriptNew}
          scriptDuplicate={this.props.explorerScriptDuplicate}
          resourceDelete={this.props.explorerResourceDelete}
          resourceRename={this.handleResourceRename}
          collapsedCategories={this.props.collapsedCategories}
          explorerToggleCategory={this.props.explorerToggleCategory}
          explorerToggleNode={this.props.explorerToggleNode}
          explorerActiveNode={this.props.explorerActiveNode}
          activeBuffer={activeBuffer}
          activeNode={this.props.activeNode}
          showModal={this.props.showModal}
          hideModal={this.props.hideModal}
        />
        <SplitPane
          split="horizontal"
          primary="second"
          {...this.replSplitSizing()}
          onChange={this.handleReplSplitChange}
          onDragFinished={this.handleReplSplitDragFinish}
        >
          {element}
          <ReplActivity {...this.replSize()} />
        </SplitPane>
      </SplitPane>
    );
  }
}

export default EditActivity;
