import api, { readLastModified } from '../api';
import {
  buffersForProject,
  sortBuffersByHierarchyDepth,
  resourceBasename,
} from './buffer-project';

export const ROOT_LIST_REQUEST = 'ROOT_LIST_REQUEST';
export const ROOT_LIST_SUCCESS = 'ROOT_LIST_SUCCESS';
export const ROOT_LIST_FAILURE = 'ROOT_LIST_FAILURE';

export const BUFFER_READ_REQUEST = 'BUFFER_READ_REQUEST';
export const BUFFER_READ_SUCCESS = 'BUFFER_READ_SUCCESS';
export const BUFFER_READ_FAILURE = 'BUFFER_READ_FAILURE';

export const DIRECTORY_READ_REQUEST = 'DIRECTORY_READ_REQUEST';
export const DIRECTORY_READ_SUCCESS = 'DIRECTORY_READ_SUCCESS';
export const DIRECTORY_READ_FAILURE = 'DIRECTORY_READ_FAILURE';

export const BUFFER_CHANGE = 'BUFFER_CHANGE';
export const BUFFER_SELECT = 'BUFFER_SELECT';

export const BUFFER_SAVE_REQUEST = 'BUFFER_SAVE_REQUEST';
export const BUFFER_SAVE_SUCCESS = 'BUFFER_SAVE_SUCCESS';
export const BUFFER_SAVE_FAILURE = 'BUFFER_SAVE_FAILURE';

export const BUFFER_MARK_STALE = 'BUFFER_MARK_STALE';
export const BUFFER_DISMISS_STALE = 'BUFFER_DISMISS_STALE';
export const BUFFER_CLEAR_STALE = 'BUFFER_CLEAR_STALE';

export const SCRIPT_NEW = 'SCRIPT_NEW';
export const SCRIPT_DUPLICATE = 'SCRIPT_DUPLICATE';

export const RESOURCE_RENAME_REQUEST = 'RESOURCE_RENAME_REQUEST';
export const RESOURCE_RENAME_SUCCESS = 'RESOURCE_RENAME_SUCCESS';
export const RESOURCE_RENAME_FAILURE = 'RESOURCE_RENAME_FAILURE';

export const RESOURCE_DELETE_REQUEST = 'RESOURCE_DELETE_REQUEST';
export const RESOURCE_DELETE_SUCCESS = 'RESOURCE_DELETE_SUCCESS';
export const RESOURCE_DELETE_FAILURE = 'RESOURCE_DELETE_FAILURE';

export const DIRECTORY_CREATE_REQUEST = 'DIRECTORY_CREATE_REQUEST';
export const DIRECTORY_CREATE_SUCCESS = 'DIRECTORY_CREATE_SUCCESS';
export const DIRECTORY_CREATE_FAILURE = 'DIRECTORY_CREATE_FAILURE';

export const TOOL_INVOKE = 'TOOL_INVOKE';

export const EXPLORER_TOGGLE_NODE = 'EXPLORER_TOGGLE_NODE';
export const EXPLORER_ACTIVE_NODE = 'EXPLORER_ACTIVE_NODE';
export const EXPLORER_REVEAL_NODE_BY_URL = 'EXPLORER_REVEAL_NODE_BY_URL';

//
// sync actions
//

export const rootListRequest = (name) => ({ type: ROOT_LIST_REQUEST, name });

export const rootListSuccess = (name, value) => ({ type: ROOT_LIST_SUCCESS, name, value });

export const rootListFailure = (name, error) => ({ type: ROOT_LIST_FAILURE, name, error });

export const bufferReadRequest = (resource) => ({ type: BUFFER_READ_REQUEST, resource });

export const bufferReadSuccess = (resource, value, contentType, lastModified) => ({
  type: BUFFER_READ_SUCCESS,
  resource,
  value,
  contentType,
  lastModified,
});

export const bufferReadFailure = (resource, error) => ({
  type: BUFFER_READ_FAILURE,
  resource,
  error,
});

export const directoryReadRequest = (resource) => ({ type: DIRECTORY_READ_REQUEST, resource });

export const directoryReadSuccess = (resource, value) => ({
  type: DIRECTORY_READ_SUCCESS,
  resource,
  value,
});

export const directoryReadFailure = (resource, error) => ({
  type: DIRECTORY_READ_FAILURE,
  resource,
  error,
});

export const bufferSaveRequest = (resource, value) => ({
  type: BUFFER_SAVE_REQUEST,
  resource,
  value,
});

export const bufferSaveSuccess = (resource, value, lastModified) => ({
  type: BUFFER_SAVE_SUCCESS,
  resource,
  value,
  lastModified,
});

export const bufferSaveFailure = (resource, error) => ({
  type: BUFFER_SAVE_FAILURE,
  resource,
  error,
});

export const bufferMarkStale = (resource) => ({ type: BUFFER_MARK_STALE, resource });

export const bufferDismissStale = (resource) => ({ type: BUFFER_DISMISS_STALE, resource });

export const bufferClearStale = (resource) => ({ type: BUFFER_CLEAR_STALE, resource });

export const bufferChange = (resource, value) => ({ type: BUFFER_CHANGE, resource, value });

export const bufferSelect = (resource) => ({ type: BUFFER_SELECT, resource });

export const scriptNew = (siblingResource, value, name, category) => ({
  type: SCRIPT_NEW,
  siblingResource,
  value,
  name,
  category,
});

export const scriptDuplicate = (resource) => ({ type: SCRIPT_DUPLICATE, resource });

export const resourceRenameRequest = (resource, name) => ({
  type: RESOURCE_RENAME_REQUEST,
  resource,
  name,
});

export const resourceRenameSuccess = (resource, newName, newResource) => ({
  type: RESOURCE_RENAME_SUCCESS,
  resource,
  newName,
  newResource,
});

export const resourceRenameFailure = (resource, name, error) => ({
  type: RESOURCE_RENAME_FAILURE,
  resource,
  name,
  error,
});

export const directoryCreateRequest = (resource, name, category) => ({
  type: DIRECTORY_CREATE_REQUEST,
  resource,
  name,
  category,
});

export const directoryCreateSuccess = (resource, name, category) => ({
  type: DIRECTORY_CREATE_SUCCESS,
  resource,
  name,
  category,
});

export const directoryCreateFailure = (resource, name, category, error) => ({
  type: DIRECTORY_CREATE_FAILURE,
  resource,
  name,
  category,
  error,
});

export const resourceDeleteRequest = (resource) => ({ type: RESOURCE_DELETE_REQUEST, resource });

export const resourceDeleteSuccess = (resource) => ({ type: RESOURCE_DELETE_SUCCESS, resource });

export const resourceDeleteFailure = (resource, error) => ({
  type: RESOURCE_DELETE_FAILURE,
  resource,
  error,
});

export const toolInvoke = (name) => ({ type: TOOL_INVOKE, name });

export const explorerActiveNode = (node) => ({ type: EXPLORER_ACTIVE_NODE, node });

export const explorerToggleNode = (node, toggled) => ({
  type: EXPLORER_TOGGLE_NODE,
  node,
  toggled,
});

export const explorerRevealNodeByURL = (url) => ({
  type: EXPLORER_REVEAL_NODE_BY_URL,
  url,
});

//
// async actions
//

export const rootList = (rootName, cb) => (dispatch) => {
  dispatch(rootListRequest(rootName));
  return api.listRoot(rootName, (response) => {
    if (response.ok) {
      response.json().then((data) => {
        dispatch(rootListSuccess(rootName, data));
        if (cb) {
          cb(rootName, data);
        }
      });
    } else {
      dispatch(rootListFailure(rootName));
    }
  });
};

export const bufferRead = (resource) => (dispatch) => {
  dispatch(bufferReadRequest(resource));
  fetch(resource, { cache: 'no-store' })
    .then((response) => {
      if (response.ok) {
        const contentType = response.headers.get('Content-Type');
        const lastModified = readLastModified(response.headers);
        if (contentType.includes('text') || contentType.includes('application/json')) {
          response.text().then((content) => {
            dispatch(bufferReadSuccess(resource, content, contentType, lastModified));
          });
        } else {
          response.blob().then((content) => {
            dispatch(bufferReadSuccess(resource, content, contentType, lastModified));
          });
        }
      } else {
        dispatch(bufferReadFailure(resource));
      }
    })
    .catch((error) => {
      dispatch(bufferReadFailure(resource, error));
    });
};

// Returns a promise of true when the device copy is newer than the buffer stamp.
export const bufferCheckStale = (resource) => (dispatch, getState) => {
  const buffer = getState().edit.buffers.get(resource);
  if (!buffer) {
    return Promise.resolve(false);
  }
  const known = buffer.get('lastModified');
  if (!known) {
    return Promise.resolve(false);
  }
  return api
    .headResource(resource)
    .then((result) => {
      if (!result.ok || !result.lastModified) {
        return false;
      }
      if (result.lastModified !== known) {
        dispatch(bufferMarkStale(resource));
        return true;
      }
      dispatch(bufferClearStale(resource));
      return false;
    })
    .catch(() => false);
};

export const directoryRead = (resource) => (dispatch) => {
  dispatch(directoryReadRequest(resource));
  return fetch(resource)
    .then((response) => {
      if (response.ok) {
        response.json().then((data) => {
          dispatch(directoryReadSuccess(resource, data));
        });
      } else {
        dispatch(directoryReadFailure(resource));
      }
    })
    .catch((error) => {
      dispatch(directoryReadFailure(resource, error));
    });
};

// This is async because nested directories don't
// like opening until their parents have loaded
export const directoryReadRecursive = (resource) => async (dispatch) => {
  if (!resource) {
    return;
  }

  await resource.split('/').reduce(async (asyncUrl, asyncPart) => {
    const url = await asyncUrl;
    const name = await asyncPart;

    if (!name) {
      return url;
    } else if (!url.includes('dust')) {
      return `${url}/${name}`;
    }

    const node = {
      name,
      url,
      children: [],
      activeBuffer: false,
      activeNode: false,
      toggled: false,
    };

    dispatch(explorerToggleNode(node, true));
    await dispatch(directoryRead(node.url));
    return `${url}/${name}`;
  });
};

export const bufferSave =
  (resource, value, cb, options = {}) =>
  (dispatch, getState) => {
    dispatch(bufferSaveRequest(resource, value));
    const buffer = getState().edit.buffers.get(resource);
    const lastModified = options.force
      ? undefined
      : options.lastModified !== undefined
        ? options.lastModified
        : buffer && buffer.get('lastModified');
    return api.writeTextResource(
      resource,
      value,
      (response) => {
        if (response.status === 412) {
          return cb ? cb({ conflict: true }) : null;
        }
        if (!response.ok) {
          response
            .json()
            .then((data) => {
              dispatch(bufferSaveFailure(resource, data.error || response.statusText));
              if (cb) {
                cb({ ok: false, error: data.error || response.statusText });
              }
            })
            .catch(() => {
              dispatch(bufferSaveFailure(resource, response.statusText));
              if (cb) {
                cb({ ok: false, error: response.statusText });
              }
            });
          return null;
        }
        const savedLastModified = readLastModified(response.headers);
        dispatch(bufferSaveSuccess(resource, response.entity, savedLastModified));
        return cb ? cb({ ok: true, lastModified: savedLastModified }) : null;
      },
      { lastModified },
    );
  };

// Save all text buffers for a project deepest-first; stop on conflict or failure.
export const saveProjectBuffers = (project) => async (dispatch, getState) => {
  const projectBuffers = buffersForProject(getState().edit.buffers, project);
  const textBuffers = projectBuffers.filter((buffer) => typeof buffer.get('value') === 'string');
  const ordered = sortBuffersByHierarchyDepth(textBuffers);
  const results = [];

  for (const [resource, buffer] of ordered) {
    // Saves must be sequential so a conflict can stop the remaining files.
    // eslint-disable-next-line no-await-in-loop
    const result = await new Promise((resolve) => {
      dispatch(bufferSave(resource, buffer.get('value'), resolve));
    });
    results.push({ resource, ...(result || {}) });
    if (!result || result.conflict || result.ok === false) {
      break;
    }
  }

  return results;
};

// HEAD every loaded project buffer and return those whose on-disk Last-Modified moved.
export const projectBuffersChangedOnDisk = (project) => async (dispatch, getState) => {
  const projectBuffers = buffersForProject(getState().edit.buffers, project);
  const ordered = sortBuffersByHierarchyDepth(projectBuffers);

  const checks = await Promise.all(
    ordered.map(async ([resource, buffer]) => {
      const known = buffer.get('lastModified');
      if (!known) {
        return null;
      }
      try {
        const result = await api.headResource(resource);
        if (!result.ok || !result.lastModified) {
          return null;
        }
        if (result.lastModified !== known) {
          dispatch(bufferMarkStale(resource));
          return { resource, name: resourceBasename(resource) };
        }
        dispatch(bufferClearStale(resource));
        return null;
      } catch (e) {
        return null;
      }
    }),
  );

  return checks.filter(Boolean);
};

export const resourceDelete = (resource, cb) => (dispatch) => {
  dispatch(resourceDeleteRequest(resource));
  return api.deleteResource(resource, (response) => {
    // FIXME: handle errors
    dispatch(resourceDeleteSuccess(resource, response.entity));
    return cb ? cb() : null;
  });
};

export const resourceRename = (resource, name, virtual) => (dispatch) => {
  dispatch(resourceRenameRequest(resource, name));
  if (virtual) {
    dispatch(resourceRenameSuccess(resource, name, undefined));
  } else {
    api.renameResource(resource, name, (response) => {
      if (response.ok) {
        response.json().then((data) => {
          dispatch(resourceRenameSuccess(resource, name, data.url));
        });
      } else {
        dispatch(resourceRenameFailure(resource, name, undefined));
      }
    });
  }
};

export const directoryCreate = (resource, name, category) => (dispatch) => {
  dispatch(directoryCreateRequest(resource, name, category));
  return api.createFolder(resource, (response) => {
    if (response.ok) {
      response.json().then(() => {
        dispatch(directoryCreateSuccess(resource, name, category));
      });
    } else {
      response.json().then((data) => {
        dispatch(directoryCreateFailure(resource, name, category, data.error));
      });
    }
  });
};
