import { beforeAll, describe, expect, it } from 'vitest';
import { assertServerReachable, uniqueId } from './helpers.js';
import { json } from './client.js';

describe('project api', () => {
  beforeAll(async () => {
    await assertServerReachable();
  });

  it('GET /api/v1/projects returns project summaries', async () => {
    const { status, body } = await json('/api/v1/projects');
    expect(status).toBe(200);
    expect(Array.isArray(body.projects)).toBe(true);
    expect(body.url).toEqual(expect.any(String));

    for (const project of body.projects) {
      expect(project).toEqual(
        expect.objectContaining({
          project_name: expect.any(String),
          managed: expect.any(Boolean),
          version: expect.any(String),
          url: expect.any(String),
        }),
      );
    }
  });

  it('GET /api/v1/project/<unknown> returns 404', async () => {
    const name = uniqueId('no_such_project');
    const { status, body } = await json(`/api/v1/project/${name}`);
    expect(status).toBe(404);
    expect(body.error).toContain('unknown project');
  });

  it('DELETE /api/v1/project/<unknown> returns 404', async () => {
    const name = uniqueId('no_such_project');
    const { status, body } = await json(`/api/v1/project/${name}`, {
      method: 'DELETE',
    });
    expect(status).toBe(404);
    expect(body.error).toContain('unknown project');
  });

  it('POST /api/v1/project/install without url returns 400', async () => {
    const { status, body } = await json('/api/v1/project/install', { method: 'POST' });
    expect(status).toBe(400);
    expect(body.error).toBe('url query arg missing');
  });

  it('POST /api/v1/project/install with invalid url returns 400', async () => {
    // %25 decodes to "%", which url.Parse rejects. A bare url=% is dropped by
    // the query parser and surfaces as "url query arg missing" instead.
    const { status, body } = await json('/api/v1/project/install?url=%25', {
      method: 'POST',
    });
    expect(status).toBe(400);
    expect(body.error).toMatch(/^invalid url:/);
  });

  it('POST /api/v1/project/install against refused zip returns install failed', async () => {
    const id = uniqueId('zipfail');
    const src = encodeURIComponent(`http://127.0.0.1:1/${id}.zip`);
    const { status, body } = await json(`/api/v1/project/install?url=${src}`, {
      method: 'POST',
    });
    expect(status).toBe(500);
    expect(body.error).toMatch(/^install failed:/);

    const leftover = await json(`/api/v1/project/${id}`);
    expect(leftover.status).toBe(404);
  });
});
