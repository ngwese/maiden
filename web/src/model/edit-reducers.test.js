// import rewire from 'rewire';
import { List, Map, Set, fromJS } from 'immutable';
import scripts from './edit-reducers';
import {
  BUFFER_READ_SUCCESS,
  BUFFER_SAVE_SUCCESS,
  BUFFER_MARK_STALE,
  BUFFER_DISMISS_STALE,
  BUFFER_CLEAR_STALE,
  BUFFER_CHANGE,
  SCRIPT_NEW,
  RESOURCE_RENAME_SUCCESS,
} from './edit-actions';

it('initial state should have empty list', () => {
  const state = scripts(undefined, { type: '@@INIT' });
  expect(state.rootNodes).toEqual(new List());
  expect(state.buffers).toEqual(new Map());
  expect(state.expandedNodes).toEqual(new Set());
});

it('BUFFER_READ_SUCCESS stores lastModified and clears stale flags', () => {
  const resource = '/api/v1/dust/code/a.lua';
  const state = scripts(undefined, {
    type: BUFFER_READ_SUCCESS,
    resource,
    value: 'print(1)',
    contentType: 'text/plain',
    lastModified: 'Sun, 06 Nov 1994 08:49:37 GMT',
  });
  const buffer = state.buffers.get(resource);
  expect(buffer.get('lastModified')).toBe('Sun, 06 Nov 1994 08:49:37 GMT');
  expect(buffer.get('stale')).toBe(false);
  expect(buffer.get('staleDismissed')).toBe(false);
  expect(buffer.get('modified')).toBe(false);
  expect(buffer.get('project')).toBeNull();
});

it('BUFFER_READ_SUCCESS tags project for nested project paths', () => {
  const resource = '/api/v1/dust/code/awake/lib/x.lua';
  const state = scripts(undefined, {
    type: BUFFER_READ_SUCCESS,
    resource,
    value: 'print(1)',
    contentType: 'text/plain',
    lastModified: 'Sun, 06 Nov 1994 08:49:37 GMT',
  });
  expect(state.buffers.get(resource).get('project')).toBe('awake');
});

it('stale mark, dismiss, and clear update buffer flags', () => {
  const resource = '/api/v1/dust/code/a.lua';
  let state = scripts(undefined, {
    type: BUFFER_READ_SUCCESS,
    resource,
    value: 'print(1)',
    contentType: 'text/plain',
    lastModified: 'Sun, 06 Nov 1994 08:49:37 GMT',
  });
  state = scripts(state, { type: BUFFER_MARK_STALE, resource });
  expect(state.buffers.get(resource).get('stale')).toBe(true);
  expect(state.buffers.get(resource).get('staleDismissed')).toBe(false);

  state = scripts(state, { type: BUFFER_DISMISS_STALE, resource });
  expect(state.buffers.get(resource).get('staleDismissed')).toBe(true);

  state = scripts(state, { type: BUFFER_CLEAR_STALE, resource });
  expect(state.buffers.get(resource).get('stale')).toBe(false);
  expect(state.buffers.get(resource).get('staleDismissed')).toBe(false);
});

it('BUFFER_SAVE_SUCCESS updates lastModified and clears stale', () => {
  const resource = '/api/v1/dust/code/a.lua';
  let state = scripts(undefined, {
    type: BUFFER_READ_SUCCESS,
    resource,
    value: 'print(1)',
    contentType: 'text/plain',
    lastModified: 'Sun, 06 Nov 1994 08:49:37 GMT',
  });
  state = scripts(state, { type: BUFFER_MARK_STALE, resource });
  state = scripts(state, {
    type: BUFFER_SAVE_SUCCESS,
    resource,
    lastModified: 'Mon, 07 Nov 1994 08:49:37 GMT',
  });
  const buffer = state.buffers.get(resource);
  expect(buffer.get('lastModified')).toBe('Mon, 07 Nov 1994 08:49:37 GMT');
  expect(buffer.get('stale')).toBe(false);
  expect(buffer.get('modified')).toBe(false);
});

it('SCRIPT_NEW beside a project file tags the new buffer with that project', () => {
  const sibling = '/api/v1/dust/code/awake/awake.lua';
  const initial = {
    activeBuffer: undefined,
    rootNodes: fromJS([
      {
        name: 'dust',
        url: '/api/v1/dust',
        children: [
          {
            name: 'code',
            url: '/api/v1/dust/code',
            children: [
              {
                name: 'awake',
                url: '/api/v1/dust/code/awake',
                children: [{ name: 'awake.lua', url: sibling }],
              },
            ],
          },
        ],
      },
    ]),
    buffers: new Map(),
    activeNode: undefined,
    expandedNodes: new Set(),
  };

  const state = scripts(initial, {
    type: SCRIPT_NEW,
    siblingResource: sibling,
    value: '-- new',
    name: 'helper.lua',
    category: 'dust',
  });

  const newResource = '/api/v1/dust/code/awake/helper.lua';
  expect(state.buffers.has(newResource)).toBe(true);
  expect(state.buffers.get(newResource).get('project')).toBe('awake');
});

it('BUFFER_CHANGE keeps the existing project tag', () => {
  const resource = '/api/v1/dust/code/awake/awake.lua';
  let state = scripts(undefined, {
    type: BUFFER_READ_SUCCESS,
    resource,
    value: 'print(1)',
    contentType: 'text/plain',
    lastModified: 'Sun, 06 Nov 1994 08:49:37 GMT',
  });
  expect(state.buffers.get(resource).get('project')).toBe('awake');

  state = scripts(state, {
    type: BUFFER_CHANGE,
    resource,
    value: 'print(2)',
  });
  expect(state.buffers.get(resource).get('project')).toBe('awake');
  expect(state.buffers.get(resource).get('modified')).toBe(true);
});

it('RESOURCE_RENAME_SUCCESS on a directory rewrites descendants and retags project', () => {
  const oldDir = '/api/v1/dust/code/awake';
  const newDir = '/api/v1/dust/code/awake2';
  const oldMain = `${oldDir}/awake.lua`;
  const oldLib = `${oldDir}/lib/x.lua`;
  const oldLibDir = `${oldDir}/lib`;
  const sibling = '/api/v1/dust/code/other/y.lua';
  const samePrefix = '/api/v1/dust/code/awake-extra/file.lua';

  const initial = {
    activeBuffer: oldLib,
    activeNode: oldDir,
    rootNodes: fromJS([
      {
        name: 'dust',
        url: '/api/v1/dust',
        children: [
          {
            name: 'code',
            url: '/api/v1/dust/code',
            children: [
              {
                name: 'awake',
                url: oldDir,
                children: [
                  { name: 'awake.lua', url: oldMain },
                  {
                    name: 'lib',
                    url: oldLibDir,
                    children: [{ name: 'x.lua', url: oldLib }],
                  },
                ],
              },
              {
                name: 'awake-extra',
                url: '/api/v1/dust/code/awake-extra',
                children: [{ name: 'file.lua', url: samePrefix }],
              },
              {
                name: 'other',
                url: '/api/v1/dust/code/other',
                children: [{ name: 'y.lua', url: sibling }],
              },
            ],
          },
        ],
      },
    ]),
    buffers: new Map({
      [oldMain]: new Map({ project: 'awake', value: 'main' }),
      [oldLib]: new Map({ project: 'awake', value: 'lib' }),
      [sibling]: new Map({ project: 'other', value: 'y' }),
      [samePrefix]: new Map({ project: 'awake-extra', value: 'extra' }),
    }),
    expandedNodes: new Set([oldDir, oldLibDir]),
  };

  const state = scripts(initial, {
    type: RESOURCE_RENAME_SUCCESS,
    resource: oldDir,
    newName: 'awake2',
    newResource: newDir,
  });

  expect(state.buffers.has(oldMain)).toBe(false);
  expect(state.buffers.has(oldLib)).toBe(false);
  expect(state.buffers.get(`${newDir}/awake.lua`).get('project')).toBe('awake2');
  expect(state.buffers.get(`${newDir}/lib/x.lua`).get('project')).toBe('awake2');
  expect(state.buffers.get(sibling).get('project')).toBe('other');
  expect(state.buffers.get(samePrefix).get('project')).toBe('awake-extra');

  expect(state.activeBuffer).toBe(`${newDir}/lib/x.lua`);
  expect(state.expandedNodes.has(newDir)).toBe(true);
  expect(state.expandedNodes.has(`${newDir}/lib`)).toBe(true);
  expect(state.expandedNodes.has(oldDir)).toBe(false);

  const awakeNode = state.rootNodes
    .getIn([0, 'children', 0, 'children'])
    .find((n) => n.get('name') === 'awake2');
  expect(awakeNode.get('url')).toBe(newDir);
  const mainNode = awakeNode.get('children').find((n) => n.get('name') === 'awake.lua');
  expect(mainNode.get('url')).toBe(`${newDir}/awake.lua`);
  const libNode = awakeNode.get('children').find((n) => n.get('name') === 'lib');
  expect(libNode.get('url')).toBe(`${newDir}/lib`);
  expect(libNode.getIn(['children', 0, 'url'])).toBe(`${newDir}/lib/x.lua`);

  // Directory rename must not insert an undefined buffer at the directory URL.
  expect(state.buffers.has(newDir)).toBe(false);
});

it('RESOURCE_RENAME_SUCCESS on a file moves only that buffer', () => {
  const resource = '/api/v1/dust/code/awake/old.lua';
  const newResource = '/api/v1/dust/code/awake/new.lua';
  const other = '/api/v1/dust/code/awake/other.lua';

  const initial = {
    activeBuffer: resource,
    activeNode: resource,
    rootNodes: fromJS([
      {
        name: 'dust',
        url: '/api/v1/dust',
        children: [
          {
            name: 'code',
            url: '/api/v1/dust/code',
            children: [
              {
                name: 'awake',
                url: '/api/v1/dust/code/awake',
                children: [
                  { name: 'old.lua', url: resource },
                  { name: 'other.lua', url: other },
                ],
              },
            ],
          },
        ],
      },
    ]),
    buffers: new Map({
      [resource]: new Map({ project: 'awake', value: 'old' }),
      [other]: new Map({ project: 'awake', value: 'other' }),
    }),
    expandedNodes: new Set(['/api/v1/dust/code/awake']),
  };

  const state = scripts(initial, {
    type: RESOURCE_RENAME_SUCCESS,
    resource,
    newName: 'new.lua',
    newResource,
  });

  expect(state.buffers.has(resource)).toBe(false);
  expect(state.buffers.get(newResource).get('project')).toBe('awake');
  expect(state.buffers.get(newResource).get('value')).toBe('old');
  expect(state.buffers.get(other).get('value')).toBe('other');
  expect(state.activeBuffer).toBe(newResource);
  expect(state.expandedNodes.has('/api/v1/dust/code/awake')).toBe(true);
});

// TODO: figure out how to test the internal functions
