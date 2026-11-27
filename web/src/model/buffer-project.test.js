import { Map } from 'immutable';
import { vi } from 'vitest';

import api from '../api';
import {
  projectForResource,
  buffersForProject,
  hierarchyDepth,
  sortBuffersByHierarchyDepth,
  isResourceRunnable,
  getDefaultRunnableResource,
  resourceIsBelow,
  rewriteResourceBelow,
  renameLoadedResourcesBelow,
} from './buffer-project';
import {
  saveProjectBuffers,
  projectBuffersChangedOnDisk,
  BUFFER_MARK_STALE,
  BUFFER_CLEAR_STALE,
} from './edit-actions';

describe('projectForResource', () => {
  it('returns project for a file under a project directory', () => {
    expect(projectForResource('/api/v1/dust/code/awake/awake.lua')).toBe('awake');
  });

  it('returns project for a nested file', () => {
    expect(projectForResource('/api/v1/dust/code/awake/lib/foo.lua')).toBe('awake');
  });

  it('returns null for a top-level code file', () => {
    expect(projectForResource('/api/v1/dust/code/a.lua')).toBeNull();
  });

  it('returns null for the project directory itself', () => {
    expect(projectForResource('/api/v1/dust/code/awake')).toBeNull();
  });

  it('returns null for dust/audio paths', () => {
    expect(projectForResource('/api/v1/dust/audio/sample.wav')).toBeNull();
  });

  it('returns null for an empty path', () => {
    expect(projectForResource('')).toBeNull();
    expect(projectForResource(undefined)).toBeNull();
  });

  it('decodes a percent-encoded project name', () => {
    expect(projectForResource('/api/v1/dust/code/my%20proj/file.lua')).toBe('my proj');
  });
});

describe('buffersForProject', () => {
  const buffers = new Map({
    '/api/v1/dust/code/awake/awake.lua': new Map({ project: 'awake', value: 'a' }),
    '/api/v1/dust/code/awake/lib/x.lua': new Map({ project: 'awake', value: 'x' }),
    '/api/v1/dust/code/other/y.lua': new Map({ project: 'other', value: 'y' }),
    '/api/v1/dust/code/a.lua': new Map({ project: null, value: 'a' }),
  });

  it('filters to buffers tagged with the project', () => {
    const result = buffersForProject(buffers, 'awake');
    expect(result.size).toBe(2);
    expect(result.has('/api/v1/dust/code/awake/awake.lua')).toBe(true);
    expect(result.has('/api/v1/dust/code/awake/lib/x.lua')).toBe(true);
  });

  it('returns an empty map when project is missing', () => {
    expect(buffersForProject(buffers, null).size).toBe(0);
    expect(buffersForProject(buffers, undefined).size).toBe(0);
    expect(buffersForProject(buffers, '').size).toBe(0);
  });
});

describe('hierarchyDepth and sortBuffersByHierarchyDepth', () => {
  it('counts non-empty path segments', () => {
    expect(hierarchyDepth('/api/v1/dust/code/a.lua')).toBe(5);
    expect(hierarchyDepth('/api/v1/dust/code/awake/lib/x.lua')).toBe(7);
  });

  it('orders deepest first and breaks ties by path ascending', () => {
    const buffers = new Map({
      '/api/v1/dust/code/awake/b.lua': new Map({ value: 'b' }),
      '/api/v1/dust/code/awake/lib/deep.lua': new Map({ value: 'd' }),
      '/api/v1/dust/code/awake/a.lua': new Map({ value: 'a' }),
    });
    const ordered = sortBuffersByHierarchyDepth(buffers).map(([resource]) => resource);
    expect(ordered).toEqual([
      '/api/v1/dust/code/awake/lib/deep.lua',
      '/api/v1/dust/code/awake/a.lua',
      '/api/v1/dust/code/awake/b.lua',
    ]);
  });
});

describe('isResourceRunnable', () => {
  it('is true for a project-root lua script', () => {
    expect(isResourceRunnable('/api/v1/dust/code/awake/awake.lua')).toBe(true);
  });

  it('is true for a top-level code lua script', () => {
    expect(isResourceRunnable('/api/v1/dust/code/foo.lua')).toBe(true);
  });

  it('is false for nested lua under a project', () => {
    expect(isResourceRunnable('/api/v1/dust/code/awake/lib/foo.lua')).toBe(false);
  });

  it('is false for non-lua files', () => {
    expect(isResourceRunnable('/api/v1/dust/code/awake/readme.md')).toBe(false);
  });

  it('is false for non-code paths', () => {
    expect(isResourceRunnable('/api/v1/dust/audio/hit.wav')).toBe(false);
  });
});

describe('getDefaultRunnableResource', () => {
  it('returns the canonical entry script path', () => {
    expect(getDefaultRunnableResource({ project: 'awake' })).toBe(
      '/api/v1/dust/code/awake/awake.lua',
    );
  });

  it('encodes the project name in the path', () => {
    expect(getDefaultRunnableResource({ project: 'my proj' })).toBe(
      '/api/v1/dust/code/my%20proj/my%20proj.lua',
    );
  });

  it('returns null when project is missing', () => {
    expect(getDefaultRunnableResource({})).toBeNull();
    expect(getDefaultRunnableResource({ project: null })).toBeNull();
    expect(getDefaultRunnableResource()).toBeNull();
  });
});

describe('resourceIsBelow and rewriteResourceBelow', () => {
  const ancestor = '/api/v1/dust/code/awake';

  it('matches a nested file', () => {
    expect(resourceIsBelow('/api/v1/dust/code/awake/lib/foo.lua', ancestor)).toBe(true);
    expect(
      rewriteResourceBelow(
        '/api/v1/dust/code/awake/lib/foo.lua',
        ancestor,
        '/api/v1/dust/code/awake2',
      ),
    ).toBe('/api/v1/dust/code/awake2/lib/foo.lua');
  });

  it('does not match the renamed path itself', () => {
    expect(resourceIsBelow(ancestor, ancestor)).toBe(false);
    expect(rewriteResourceBelow(ancestor, ancestor, '/api/v1/dust/code/awake2')).toBe(ancestor);
  });

  it('does not match a same-prefix sibling', () => {
    expect(resourceIsBelow('/api/v1/dust/code/awake-extra/file.lua', ancestor)).toBe(false);
  });

  it('does not match an unrelated path', () => {
    expect(resourceIsBelow('/api/v1/dust/code/other/x.lua', ancestor)).toBe(false);
  });
});

describe('renameLoadedResourcesBelow', () => {
  it('rekeys nested buffers, recomputes project, and leaves others in place', () => {
    const buffers = new Map({
      '/api/v1/dust/code/awake/awake.lua': new Map({ project: 'awake', value: 'main' }),
      '/api/v1/dust/code/awake/lib/x.lua': new Map({ project: 'awake', value: 'lib' }),
      '/api/v1/dust/code/other/y.lua': new Map({ project: 'other', value: 'y' }),
    });
    const next = renameLoadedResourcesBelow(
      buffers,
      '/api/v1/dust/code/awake',
      '/api/v1/dust/code/awake2',
    );

    expect(next.has('/api/v1/dust/code/awake/awake.lua')).toBe(false);
    expect(next.get('/api/v1/dust/code/awake2/awake.lua').get('project')).toBe('awake2');
    expect(next.get('/api/v1/dust/code/awake2/lib/x.lua').get('project')).toBe('awake2');
    expect(next.get('/api/v1/dust/code/other/y.lua').get('project')).toBe('other');
  });
});

describe('saveProjectBuffers', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('saves text buffers deepest-first, skips blobs, and stops on conflict', async () => {
    const deep = '/api/v1/dust/code/awake/lib/deep.lua';
    const firstShallow = '/api/v1/dust/code/awake/a.lua';
    const secondShallow = '/api/v1/dust/code/awake/mid.lua';
    const blob = '/api/v1/dust/code/awake/sample.bin';

    const buffers = new Map({
      [deep]: new Map({ project: 'awake', value: 'deep', lastModified: 't1' }),
      [firstShallow]: new Map({ project: 'awake', value: 'a', lastModified: 't2' }),
      [secondShallow]: new Map({ project: 'awake', value: 'mid', lastModified: 't3' }),
      [blob]: new Map({ project: 'awake', value: new Blob(['x']), lastModified: 't4' }),
    });

    const writeOrder = [];
    vi.spyOn(api, 'writeTextResource').mockImplementation((resource, _value, cb) => {
      writeOrder.push(resource);
      if (resource === firstShallow) {
        cb({ status: 412, ok: false });
        return Promise.resolve();
      }
      cb({
        status: 200,
        ok: true,
        entity: 'ok',
        headers: {
          get: () => 'Mon, 07 Nov 1994 08:49:37 GMT',
        },
      });
      return Promise.resolve();
    });

    const dispatch = vi.fn((action) => {
      if (typeof action === 'function') {
        return action(dispatch, () => ({ edit: { buffers } }));
      }
      return action;
    });
    const getState = () => ({ edit: { buffers } });

    const results = await saveProjectBuffers('awake')(dispatch, getState);

    expect(writeOrder).toEqual([deep, firstShallow]);
    expect(writeOrder).not.toContain(blob);
    expect(writeOrder).not.toContain(secondShallow);
    expect(results).toEqual([
      { resource: deep, ok: true, lastModified: 'Mon, 07 Nov 1994 08:49:37 GMT' },
      { resource: firstShallow, conflict: true },
    ]);
  });
});

describe('projectBuffersChangedOnDisk', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('returns only buffers whose Last-Modified moved, deepest-first', async () => {
    const movedDeep = '/api/v1/dust/code/awake/lib/moved.lua';
    const movedShallow = '/api/v1/dust/code/awake/moved.lua';
    const dirtyMatch = '/api/v1/dust/code/awake/dirty.lua';
    const nestedMatch = '/api/v1/dust/code/awake/lib/ok.lua';
    const noStamp = '/api/v1/dust/code/awake/new.lua';
    const failedHead = '/api/v1/dust/code/awake/fail.lua';

    const stamp = 'Sun, 06 Nov 1994 08:49:37 GMT';
    const newer = 'Mon, 07 Nov 1994 08:49:37 GMT';

    const buffers = new Map({
      [movedDeep]: new Map({
        project: 'awake',
        value: 'd',
        modified: false,
        lastModified: stamp,
      }),
      [movedShallow]: new Map({
        project: 'awake',
        value: 's',
        modified: false,
        lastModified: stamp,
      }),
      [dirtyMatch]: new Map({
        project: 'awake',
        value: 'dirty',
        modified: true,
        lastModified: stamp,
      }),
      [nestedMatch]: new Map({
        project: 'awake',
        value: 'ok',
        modified: false,
        lastModified: stamp,
      }),
      [noStamp]: new Map({ project: 'awake', value: 'new', modified: true, lastModified: null }),
      [failedHead]: new Map({
        project: 'awake',
        value: 'fail',
        modified: false,
        lastModified: stamp,
      }),
    });

    vi.spyOn(api, 'headResource').mockImplementation(async (resource) => {
      if (resource === failedHead) {
        throw new Error('network');
      }
      if (resource === movedDeep || resource === movedShallow) {
        return { ok: true, lastModified: newer };
      }
      return { ok: true, lastModified: stamp };
    });

    const dispatched = [];
    const dispatch = vi.fn((action) => {
      dispatched.push(action);
      return action;
    });
    const getState = () => ({ edit: { buffers } });

    const changed = await projectBuffersChangedOnDisk('awake')(dispatch, getState);

    expect(changed).toEqual([
      { resource: movedDeep, name: 'moved.lua' },
      { resource: movedShallow, name: 'moved.lua' },
    ]);

    const markStale = dispatched.filter((a) => a && a.type === BUFFER_MARK_STALE);
    const clearStale = dispatched.filter((a) => a && a.type === BUFFER_CLEAR_STALE);
    expect(markStale.map((a) => a.resource).sort()).toEqual([movedDeep, movedShallow].sort());
    expect(clearStale.map((a) => a.resource).sort()).toEqual([dirtyMatch, nestedMatch].sort());
  });
});
