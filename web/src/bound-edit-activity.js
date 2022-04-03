import { connect } from 'react-redux';
import { createSelector } from 'reselect';
import { push as pushHistory } from 'connected-react-router';
import EditActivity from './edit-activity';
import { NORNS_COMPONENT, UNTITLED_SCRIPT, USER_DATA_PATH } from './constants';
import { nodeForResource } from './model/listing';
import api, { DUST_CODE_RESOURCE } from './api';
import { resourceToEditPath } from './url-utils';

import {
  rootList,
  bufferRead,
  directoryRead,
  bufferSave,
  bufferChange,
  bufferSelect,
  scriptNew,
  scriptDuplicate,
  resourceDelete,
  resourceRename,
  toolInvoke,
  explorerActiveNode,
  explorerToggleNode,
  explorerRevealNodeByURL,
  directoryCreate,
} from './model/edit-actions';

import {
  sidebarToggle,
  sidebarSize,
  replToggle,
  replSize,
  toggleCategory,
} from './model/ui-actions';

import { replSend } from './model/repl-actions';

import { editorConfig } from './model/config-actions';

const getBuffers = editState => editState.buffers;
const getActiveBuffer = editState => editState.activeBuffer;
const getActiveNodeResource = editState => editState.activeNode;
const getRootNodes = editState => editState.rootNodes;
const getExpandedNodes = editState => editState.expandedNodes;

const getExplorerData = createSelector(
  [getBuffers, getActiveBuffer, getActiveNodeResource, getRootNodes, getExpandedNodes],
  (buffers, activeBuffer, activeNode, rootNodes, expandedNodes) => {
    // enrich script listing w/ modification state, etc.

    const enrich = items =>
      items.map(l => {
        const item = { ...l };
        item.activeBuffer = l.url === activeBuffer;
        item.activeNode = l.url === activeNode;
        item.toggled = expandedNodes.has(l.url);

        const buffer = buffers.get(l.url);
        if (buffer) {
          item.loaded = true;
          item.modified = buffer.get('modified') || false;
          item.virtual = buffer.get('virtual') || false;
        }

        if (item.children) {
          item.children = enrich(item.children);
        }

        return item;
      });

    return enrich(rootNodes.toJS());
  },
);

const getActiveNode = createSelector(
  [getActiveNodeResource, getRootNodes],
  (activeNode, rootNodes) => nodeForResource(rootNodes, activeNode),
);

const mapStateToProps = state => {
  const { activeBuffer, buffers } = state.edit;
  return {
    activeBuffer,
    activeNode: getActiveNode(state.edit),
    buffers,
    ui: state.ui,
    explorerData: getExplorerData(state.edit),
    collapsedCategories: state.ui.collapsedCategories,
    editorOptions: state.config.editor,
  };
};

const mapDispatchToProps = dispatch => ({
  // scripts
  scriptList: () => {
    dispatch(rootList('scripts'));
  },
  dataList: () => {
    dispatch(rootList('data'));
  },
  audioList: () => {
    dispatch(rootList('audio'));
  },
  bufferRead: resource => {
    dispatch(bufferRead(resource));
  },
  directoryRead: resource => {
    dispatch(directoryRead(resource));
  },
  bufferChange: (resource, value) => {
    dispatch(bufferChange(resource, value));
  },
  bufferSelect: resource => {
    dispatch(bufferSelect(resource));

    const path = resourceToEditPath(resource);
    if (path) {
      dispatch(pushHistory(path));
    }
  },
  bufferSave: (resource, code, completionCB = () => {}) => {
    dispatch(bufferSave(resource, code, completionCB));
  },
  scriptRun: resource => {
    const file = api.fileFromResource(resource);
    if (file) {
      if (file.includes('/lib/') || file.includes('/data/') || file.includes('/audio/')) {
        console.log('files under /lib/, /data/, and /audio/ cannot be run as a script');
        return;
      }
      const cmd = `norns.script.load("${file}")`;
      dispatch(replSend(NORNS_COMPONENT, cmd));
    } else {
      console.log('resource:', resource, 'cannot be run as a script');
    }
  },
  scriptClear: () => {
    const cmd = 'norns.script.clear()';
    dispatch(replSend(NORNS_COMPONENT, cmd));
  },
  selectionEval: code => {
    dispatch(replSend(NORNS_COMPONENT, code));
  },

  // ui
  sidebarToggle: () => {
    dispatch(sidebarToggle());
  },
  sidebarSize: width => {
    dispatch(sidebarSize(width));
  },
  replToggle: () => {
    dispatch(replToggle());
  },
  replSize: height => {
    dispatch(replSize(height));
  },

  // tools
  toolInvoke: name => {
    dispatch(toolInvoke(name));
  },

  // explorer
  explorerActiveNode: node => {
    dispatch(explorerActiveNode(node));
  },
  explorerToggleNode: (node, toggled) => {
    dispatch(explorerToggleNode(node, toggled));
  },
  explorerScriptNew: (sibling, value, name, category) => {
    dispatch(scriptNew(sibling, value, name, category));
  },
  explorerScriptDuplicate: source => {
    dispatch(scriptDuplicate(source));
  },
  explorerResourceDelete: resource => {
    dispatch(resourceDelete(resource));
  },
  explorerResourceRename: (activeNode, newName, virtual) => {
    dispatch(resourceRename(activeNode, newName, virtual));
  },
  explorerDirectoryCreate: (resource, name, category) => {
    dispatch(directoryCreate(resource, name, category));
  },
  explorerToggleCategory: name => {
    dispatch(toggleCategory(name));
  },

  // editor
  editorScriptNew: () => {
    dispatch(scriptNew(DUST_CODE_RESOURCE, undefined, UNTITLED_SCRIPT, USER_DATA_PATH));
    dispatch(explorerRevealNodeByURL(DUST_CODE_RESOURCE));
  },

  // config
  editorConfig: resource => {
    dispatch(editorConfig(resource));
  },
});

const BoundEditActivity = connect(mapStateToProps, mapDispatchToProps)(EditActivity);

export default BoundEditActivity;
