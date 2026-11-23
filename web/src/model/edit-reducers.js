import { Map, List, Set, fromJS } from 'immutable';

import {
  keyPathForResource,
  keyPathParent,
  nodeForResource,
  spliceDirInfo,
  spliceFileInfo,
  generateNodeName,
  virtualNode,
  collectVirtualNodes,
  spliceNodes,
  sortDir,
  rootCategoryIndex,
  childrenOfRoot,
  directoryNode,
  nodeIsDir,
} from './listing';

import {
  ROOT_LIST_SUCCESS,
  BUFFER_READ_SUCCESS,
  DIRECTORY_READ_SUCCESS,
  BUFFER_SAVE_SUCCESS,
  BUFFER_SELECT,
  BUFFER_CHANGE,
  BUFFER_MARK_STALE,
  BUFFER_DISMISS_STALE,
  BUFFER_CLEAR_STALE,
  SCRIPT_NEW,
  RESOURCE_DELETE_SUCCESS,
  SCRIPT_DUPLICATE,
  DIRECTORY_CREATE_SUCCESS,
  RESOURCE_RENAME_SUCCESS,
  TOOL_INVOKE,
  EXPLORER_ACTIVE_NODE,
  EXPLORER_TOGGLE_NODE,
  EXPLORER_REVEAL_NODE_BY_URL,
  scriptNew,
} from './edit-actions';

import { bufferIsEditable } from './edit-helpers';

import api, { DUST_CODE_RESOURCE } from '../api';
import { UNTITLED_SCRIPT } from '../constants';

/*

edit: {
    activeNode: <url>,
    expandedNodes: Set(),
    rootNodes: [
        { name: ..., url: ... },
        { name: ..., url:... , children: [
            <more rootNodes>
        ]}
    ]
    activeBuffer: <url>,
    buffers: Map({
        <url>: {
            value: <string>,
            modified: <bool>,
            contentType: <string>,
            lastModified: <string|null>,
            stale: <bool>,
            staleDismissed: <bool>,
        }
    })
}

*/

const handleScriptNew = (action, state) => {
  if (action.name === undefined && action.siblingResource === undefined) {
    console.log('ignoring script new request, neither name nor placement specified');
    return state;
  }

  const category = action.category || 'dust';
  const categoryIndex = rootCategoryIndex(state.rootNodes, category);

  // assume script will be placed at the top of the hierarchy (by default)
  let siblings = childrenOfRoot(state.rootNodes, categoryIndex);
  let siblingIsDir = false;

  const childPath = keyPathForResource(state.rootNodes, action.siblingResource);

  if (childPath) {
    // a sibling exists, use that level of hierarchy for name computation
    const siblingNode = state.rootNodes.getIn(childPath);
    siblingIsDir = nodeIsDir(siblingNode);
    if (siblingIsDir) {
      // "selected" sibling is dirtoJS so use the directories children as the "siblings" for name generation and placement
      siblings = state.rootNodes.getIn(childPath.push('children'));
    } else {
      // "selected" sibling is file so use its parent directory's children as the "siblings" for name generation and placement
      siblings = state.rootNodes.getIn(childPath.pop());
    }
  }

  const newName = generateNodeName(siblings, action.name || UNTITLED_SCRIPT);

  let newResource;
  if (siblingIsDir) {
    newResource = api.childResourceForName(newName, action.siblingResource, category);
  } else {
    newResource = api.siblingResourceForName(newName, action.siblingResource, category);
  }

  const newBuffer = new Map({
    modified: true,
    value: action.value || '',
    contentType: 'text/utf-8',
  });

  const newNode = virtualNode(newName, newResource);
  const newRootNodes = spliceFileInfo(
    state.rootNodes,
    newNode,
    action.siblingResource,
    categoryIndex,
  );

  return {
    ...state,
    rootNodes: newRootNodes,
    activeBuffer: newResource,
    buffers: state.buffers.set(newResource, newBuffer),
  };
};

const handleBufferChange = (action, state) => {
  if (action.resource === undefined) {
    console.log('implicitly creating new script');
    return handleScriptNew(scriptNew(DUST_CODE_RESOURCE, action.value, undefined, 'dust'), state);
  }

  const buffer = state.buffers.get(action.resource);
  if (buffer === undefined) {
    console.log('ignoring change for missing buffer (possibly deleted):', action.resource);
    return state;
  }

  // FIXME: super janky hack to prevent marking binary buffers dirty, this needs to be removed when proper alt ui is in place for the editor when binary files are selected
  if (!bufferIsEditable(buffer)) {
    console.log('ignoring buffer change for binary buffer');
    return state;
  }

  const modified = buffer.get('modified') || buffer.get('value') !== action.value; // FIXME: inefficient?
  const changes = new Map({
    value: action.value,
    modified,
    contentType: buffer.get('contentType'),
  });
  return { ...state, buffers: state.buffers.set(action.resource, buffer.merge(changes)) };
};

const handleRootList = (action, state) => {
  // FIXME: change the virtualNode resource to be the api path
  let rootNode = directoryNode(action.name, action.value.url, fromJS(action.value.entries));

  const existingRootIndex = state.rootNodes.findIndex(n => n.get('name') === action.name);
  if (existingRootIndex > 0) {
    const virtuals = collectVirtualNodes(state.rootNodes.getIn([existingRootIndex, 'children']));
    const rootChildren = rootNode.get('children');
    rootNode = rootNode.set('children', spliceNodes(rootChildren, virtuals));
  }

  let rootNodes;
  if (existingRootIndex > 0) {
    rootNodes = sortDir(
      state.rootNodes.set(existingRootIndex, rootNode),
      new List([existingRootIndex]),
    );
  } else {
    rootNodes = state.rootNodes.push(rootNode);
    rootNodes = sortDir(rootNodes, new List([rootNodes.size - 1]));
  }

  return { ...state, rootNodes };
};

// IDEA: might be cool if this copied 'template.lua' as a starting point

const handleResourceDeleteSuccess = (action, state) => {
  console.log('in handleResourceDelete()', action);
  const childPath = keyPathForResource(state.rootNodes, action.resource);
  const newRootNodes = state.rootNodes.removeIn(childPath);
  const newActiveBuffer = state.activeBuffer === action.resource ? undefined : state.activeBuffer;

  return {
    ...state,
    rootNodes: newRootNodes,
    activeBuffer: newActiveBuffer,
    buffers: state.buffers.delete(action.resource),
  };
};

const handleScriptDuplicate = (action, state) => {
  if (!action.resource) {
    // can't duplicate without a resource
    return state;
  }

  const sourceNode = nodeForResource(state.rootNodes, action.resource);
  if (!sourceNode) {
    console.log('cannot find existing resource to duplicate');
    return state;
  }

  const sourceBuffer = state.buffers.get(action.resource);
  const newAction = scriptNew(action.resource, sourceBuffer.get('value'), sourceNode.get('name'));

  return handleScriptNew(newAction, state);
};

const handleDirectoryCreateSuccess = (action, state) => {
  // console.log('dir success:', action.category, action.resource);
  const newNode = directoryNode(action.name, action.resource);
  const newRootNodes = spliceNodes(state.rootNodes, new List([newNode]));

  return {
    ...state,
    rootNodes: newRootNodes,
  };
};

const handleResourceRenameSuccess = (action, state) => {
  console.log('rename success: ', action);

  let newResource = action.newResource;
  if (!newResource) {
    // assume this is virtual; fabricate new url
    newResource = api.siblingResourceForName(action.newName, action.resource);
    console.log(action.resource, ' => ', newResource);
  }

  const oldNode = nodeForResource(state.rootNodes, action.resource);
  const newNode = oldNode.set('url', newResource).set('name', action.newName);

  const keyPath = keyPathForResource(state.rootNodes, action.resource);
  let rootNodes = state.rootNodes.setIn(keyPath, newNode);

  // sort parent dir of node
  const dirPath = keyPathParent(keyPath);

  rootNodes = sortDir(rootNodes, dirPath);

  // update active buffer if pointing at the renamed resource
  const activeBuffer = state.activeBuffer === action.resource ? newResource : state.activeBuffer;

  // buffers are keyed by resource, modify that too
  const buffers = state.buffers
    .set(newResource, state.buffers.get(action.resource))
    .delete(action.resource);

  return {
    ...state,
    activeBuffer,
    rootNodes,
    buffers,
    activeNode: newResource,
  };
};

const initialEditState = {
  activeBuffer: undefined,
  rootNodes: new List(),
  buffers: new Map(),
  activeNode: undefined,
  expandedNodes: new Set(),
};

const edit = (state = initialEditState, action) => {
  switch (action.type) {
    case ROOT_LIST_SUCCESS:
      return handleRootList(action, state);

    case BUFFER_READ_SUCCESS:
      return {
        ...state,
        buffers: state.buffers.set(
          action.resource,
          new Map({
            value: action.value,
            modified: false,
            contentType: action.contentType,
            lastModified: action.lastModified || null,
            stale: false,
            staleDismissed: false,
          }),
        ),
      };

    case DIRECTORY_READ_SUCCESS:
      // console.log("splice", state.rootNodes, action.resource, action.value)
      return {
        ...state,
        rootNodes: spliceDirInfo(state.rootNodes, action.resource, fromJS(action.value.entries)),
      };

    case BUFFER_SAVE_SUCCESS: {
      const existing = state.buffers.get(action.resource);
      if (!existing) {
        return state;
      }
      let savedBuffer = existing
        .set('modified', false)
        .set('stale', false)
        .set('staleDismissed', false);
      if (action.lastModified) {
        savedBuffer = savedBuffer.set('lastModified', action.lastModified);
      }
      if (savedBuffer.has('virtual')) {
        savedBuffer = savedBuffer.delete('virtual');
      }
      return {
        ...state,
        buffers: state.buffers.set(action.resource, savedBuffer),
      };
    }

    case BUFFER_MARK_STALE: {
      const buffer = state.buffers.get(action.resource);
      if (!buffer) {
        return state;
      }
      return {
        ...state,
        buffers: state.buffers.set(
          action.resource,
          buffer.set('stale', true).set('staleDismissed', false),
        ),
      };
    }

    case BUFFER_DISMISS_STALE: {
      const buffer = state.buffers.get(action.resource);
      if (!buffer) {
        return state;
      }
      return {
        ...state,
        buffers: state.buffers.set(action.resource, buffer.set('staleDismissed', true)),
      };
    }

    case BUFFER_CLEAR_STALE: {
      const buffer = state.buffers.get(action.resource);
      if (!buffer) {
        return state;
      }
      return {
        ...state,
        buffers: state.buffers.set(
          action.resource,
          buffer.set('stale', false).set('staleDismissed', false),
        ),
      };
    }

    case BUFFER_SELECT:
      return { ...state, activeBuffer: action.resource };

    case BUFFER_CHANGE:
      return handleBufferChange(action, state);

    case SCRIPT_NEW:
      return handleScriptNew(action, state);

    case SCRIPT_DUPLICATE:
      return handleScriptDuplicate(action, state);

    case RESOURCE_DELETE_SUCCESS:
      return handleResourceDeleteSuccess(action, state);

    case RESOURCE_RENAME_SUCCESS:
      return handleResourceRenameSuccess(action, state);

    case DIRECTORY_CREATE_SUCCESS:
      return handleDirectoryCreateSuccess(action, state);

    case TOOL_INVOKE:
      console.log('tool invoke => ', action.name);
      return state;

    case EXPLORER_ACTIVE_NODE:
      return { ...state, activeNode: action.node.url };

    case EXPLORER_TOGGLE_NODE:
      if (action.toggled) {
        return { ...state, expandedNodes: state.expandedNodes.add(action.node.url) };
      }
      return { ...state, expandedNodes: state.expandedNodes.delete(action.node.url) };

    case EXPLORER_REVEAL_NODE_BY_URL:
      return { ...state, expandedNodes: state.expandedNodes.add(action.url) };

    default:
      return state;
  }
};

export default edit;
