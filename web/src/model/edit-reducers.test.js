// import rewire from 'rewire';
import { List, Map, Set } from 'immutable';
import scripts from './edit-reducers';
import {
  BUFFER_READ_SUCCESS,
  BUFFER_SAVE_SUCCESS,
  BUFFER_MARK_STALE,
  BUFFER_DISMISS_STALE,
  BUFFER_CLEAR_STALE,
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

// TODO: figure out how to test the internal functions
