import React, { Component } from 'react';
import { Group, Panel, Separator } from 'react-resizable-panels';
import Explorer from './explorer';
import Editor from './editor';
import ToolBar from './tool-bar';
import IconButton from './icon-button';
import ModalContent from './modal-content';
import AudioListener from './audio-listener';
import { ICONS } from './svg-icons';
import { commandService } from './services';
import OS from './utils';
import { bufferIsEditable, bufferIsAudio } from './model/edit-helpers';
import ReplActivity from './bound-repl-activity';

import './edit-activity.css';

const STALE_BANNER_HEIGHT = 32;

const resourceBasename = (resource) => {
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

const EditTools = (props) => {
  const items = props.tools.map((tool) => (
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
    // sidebarWidth / replHeight remember the last open size for restore.
    // sidebarLayoutWidth / replLayoutHeight track live panel pixels (including
    // collapsedSize) so the editor can fill space when a panel snaps shut.
    this.state = {
      toolbarWidth: 50,
      sidebarWidth: props.ui.sidebarWidth,
      sidebarLayoutWidth: props.ui.sidebarHidden ? 1 : props.ui.sidebarWidth,
      replHeight: props.ui.replHeight,
      replLayoutHeight: props.ui.replHidden ? 0 : props.ui.replHeight,
    };

    // defaultSize must stay stable: react-resizable-panels re-registers the panel
    // when it changes, which cancels an in-progress drag.
    this.sidebarDefaultSize = props.ui.sidebarHidden ? 1 : props.ui.sidebarWidth;
    this.replDefaultSize = props.ui.replHidden ? 0 : props.ui.replHeight;
    this.sidebarPanelRef = React.createRef();
    this.replPanelRef = React.createRef();
  }

  syncSidebarPanel() {
    const sidebarPanel = this.sidebarPanelRef.current;
    if (!sidebarPanel) {
      return;
    }
    if (this.props.ui.sidebarHidden) {
      sidebarPanel.collapse();
    } else if (sidebarPanel.isCollapsed()) {
      sidebarPanel.expand();
      sidebarPanel.resize(this.state.sidebarWidth);
    }
  }

  syncReplPanel() {
    const replPanel = this.replPanelRef.current;
    if (!replPanel) {
      return;
    }
    if (this.props.ui.replHidden) {
      replPanel.collapse();
    } else if (replPanel.isCollapsed()) {
      replPanel.expand();
      replPanel.resize(this.state.replHeight);
    }
  }

  componentDidMount() {
    this.syncSidebarPanel();
    this.syncReplPanel();
  }

  getSnapshotBeforeUpdate(prevProps) {
    // Capture Monaco text for the previous buffer before Editor switches
    // models.
    //
    // FIXME: Revisit this approach as some point as it may not fully apply to
    // the setup with Monaco. With Ace there was only a single instance and the
    // buffer data was held internal to the instance so buffer switch meant
    // swapping contents. With Monace there are multiple model instances with
    // separate buffers/undo stacks etc. A future side-by-side presentation
    // would require a different way to associate buffer with the editor instance.
    const { activeBuffer, buffers } = prevProps;
    if (activeBuffer !== this.props.activeBuffer && buffers.has(activeBuffer) && this.editor) {
      return this.editor.getValue();
    }
    return null;
  }

  componentDidUpdate(prevProps, _prevState, snapshot) {
    if (snapshot != null) {
      this.props.bufferChange(prevProps.activeBuffer, snapshot);
    }

    const { activeBuffer, buffers } = this.props;
    if (activeBuffer && !buffers.has(activeBuffer)) {
      // active buffer isn't (yet) loaded, trigger read
      this.props.bufferRead(activeBuffer);
    } else if (
      activeBuffer &&
      activeBuffer !== prevProps.activeBuffer &&
      buffers.has(activeBuffer)
    ) {
      // switching back to an already-buffered file; check device mtime
      this.props.bufferCheckStale(activeBuffer);
    }

    // Sync only the panel whose hidden flag changed. Syncing both would
    // expand a snap-closed panel that is collapsed but not yet marked hidden.
    if (prevProps.ui.sidebarHidden !== this.props.ui.sidebarHidden) {
      this.syncSidebarPanel();
    }
    if (prevProps.ui.replHidden !== this.props.ui.replHidden) {
      this.syncReplPanel();
    }
  }

  getSidebarLayoutWidth() {
    // Toggle-hidden applies before onResize; snap-closed uses live pixels.
    return this.props.ui.sidebarHidden ? 1 : this.state.sidebarLayoutWidth;
  }

  getEditorHeight() {
    // Toggle-hidden reclaims the separator too; snap-closed leaves it.
    return this.props.ui.replHidden
      ? this.props.height
      : this.props.height - this.state.replLayoutHeight - 1;
  }

  showStaleBanner(buffer) {
    return Boolean(buffer && buffer.get('stale') && !buffer.get('staleDismissed'));
  }

  editorSize(bannerVisible) {
    const sidebarWidth = this.getSidebarLayoutWidth();
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
      width: this.props.width - this.getSidebarLayoutWidth(),
      height: this.state.replLayoutHeight,
    };
  }

  handleSidebarResize = (panelSize) => {
    const size = panelSize.inPixels;
    if (this.props.ui.sidebarHidden && size > 1) {
      // reveal when dragging out of the collapsed strip
      this.props.sidebarToggle();
    } else if (!this.props.ui.sidebarHidden && size <= 1) {
      // snap-closed: keep Redux hidden in sync so toggles don't need two clicks
      this.props.sidebarToggle();
    }
    const next = { sidebarLayoutWidth: size };
    if (size >= this.props.ui.sidebarMinWidth) {
      next.sidebarWidth = size;
    }
    this.setState(next);
  };

  handleSidebarLayoutChanged = (_layout, meta) => {
    if (meta.isUserInteraction && this.state.sidebarWidth >= this.props.ui.sidebarMinWidth) {
      this.props.sidebarSize(this.state.sidebarWidth);
    }
  };

  handleReplResize = (panelSize) => {
    const size = panelSize.inPixels;
    if (this.props.ui.replHidden && size > 0) {
      this.props.replToggle();
    } else if (!this.props.ui.replHidden && size <= 0) {
      this.props.replToggle();
    }
    const next = { replLayoutHeight: size };
    if (size >= this.props.ui.replMinHeight) {
      next.replHeight = size;
    }
    this.setState(next);
  };

  handleReplLayoutChanged = (_layout, meta) => {
    if (meta.isUserInteraction && this.state.replHeight >= this.props.ui.replMinHeight) {
      this.props.replSize(this.state.replHeight);
    }
  };

  getActiveBuffer = () => this.props.buffers.get(this.props.activeBuffer);

  saveActiveBuffer = (afterSave, options = {}) => {
    const resource = this.props.activeBuffer;
    const value = this.editor.getValue();
    this.editor.bufferWillSave(resource);
    this.props.bufferSave(
      resource,
      value,
      (result) => {
        if (result && result.conflict) {
          const name = resourceBasename(resource);
          this.props.showModal(
            <ModalContent
              message="File changed on device. Overwrite?"
              supporting={name}
              buttonAction={(choice) => {
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

  handleToolInvoke = (tool) => {
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
        Promise.resolve(this.props.bufferCheckStale(resource)).then((stale) => {
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

  isText = (buffer) => buffer && bufferIsEditable(buffer);

  isAudio = (buffer) => buffer && bufferIsAudio(buffer);

  render() {
    const activeBuffer = this.props.activeBuffer;
    const buffer = this.getActiveBuffer();

    const canEdit = this.isText(buffer);
    const code = canEdit ? buffer.get('value') : '';

    const canListen = this.isAudio(buffer);

    const enabledTools = tools.map((t) => ({ ...t, disabled: !(canEdit || t.alwaysEnable) }));

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
            ref={(component) => {
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

    const listener =
      buffer && canListen ? (
        <div className="listener-pane">
          <AudioListener key={activeBuffer} blob={buffer.get('value')} />
        </div>
      ) : null;

    const loading = (
      <div className="spinner-pane">
        <div className="spinner" />
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

    const { ui } = this.props;
    // Panel defaults to overflow:auto via inline style; only the style prop overrides it.
    const panelStyle = { overflow: 'hidden' };

    return (
      <Group
        orientation="horizontal"
        className="edit-activity-split"
        style={sidebarSplitStyle}
        onLayoutChanged={this.handleSidebarLayoutChanged}
      >
        <Panel
          id="sidebar"
          className="editor-pane-common"
          style={panelStyle}
          panelRef={this.sidebarPanelRef}
          collapsible
          collapsedSize={1}
          defaultSize={this.sidebarDefaultSize}
          minSize={ui.sidebarMinWidth}
          maxSize={ui.sidebarMaxWidth}
          onResize={this.handleSidebarResize}
        >
          <Explorer
            className="explorer-container"
            hidden={ui.sidebarHidden}
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
            sectionOrder={this.props.sectionOrder}
            sectionHeights={this.props.sectionHeights}
            autoHideSections={this.props.editorOptions && this.props.editorOptions.autoHideSections}
            explorerToggleCategory={this.props.explorerToggleCategory}
            explorerReorderSections={this.props.explorerReorderSections}
            explorerSetSectionHeights={this.props.explorerSetSectionHeights}
            explorerToggleNode={this.props.explorerToggleNode}
            explorerActiveNode={this.props.explorerActiveNode}
            activeBuffer={activeBuffer}
            activeNode={this.props.activeNode}
            showModal={this.props.showModal}
            hideModal={this.props.hideModal}
          />
        </Panel>
        <Separator className="edit-activity-separator edit-activity-separator-vertical" />
        <Panel id="main" className="editor-pane-common" style={panelStyle}>
          <Group
            orientation="vertical"
            className="edit-activity-split"
            style={{ height: '100%', width: '100%' }}
            onLayoutChanged={this.handleReplLayoutChanged}
          >
            <Panel
              id="editor"
              className="editor-pane-common"
              style={panelStyle}
              minSize={ui.editorMinHeight}
            >
              {element}
            </Panel>
            <Separator className="edit-activity-separator edit-activity-separator-horizontal" />
            <Panel
              id="repl"
              className="editor-pane-common"
              style={panelStyle}
              panelRef={this.replPanelRef}
              collapsible
              collapsedSize={0}
              defaultSize={this.replDefaultSize}
              minSize={ui.replMinHeight}
              onResize={this.handleReplResize}
            >
              <ReplActivity {...this.replSize()} />
            </Panel>
          </Group>
        </Panel>
      </Group>
    );
  }
}

export default EditActivity;
