import { beforeAll, describe, expect, it } from 'vitest';
import { assertServerReachable, uniqueId } from './helpers.js';
import { json } from './client.js';

describe('catalog api', () => {
  beforeAll(async () => {
    await assertServerReachable();
  });

  it('GET /api/v1/catalogs returns catalog summaries', async () => {
    const { status, body } = await json('/api/v1/catalogs');
    expect(status).toBe(200);
    expect(Array.isArray(body.catalogs)).toBe(true);
    expect(body.url).toEqual(expect.any(String));

    for (const entry of body.catalogs) {
      expect(entry).toEqual(
        expect.objectContaining({
          name: expect.any(String),
          url: expect.any(String),
          date: expect.any(String),
        }),
      );
    }
  });

  it('GET /api/v1/catalog/<unknown> returns 404', async () => {
    const name = uniqueId('no_such_catalog');
    const { status, body } = await json(`/api/v1/catalog/${name}`);
    expect(status).toBe(404);
    expect(body).toEqual(
      expect.objectContaining({
        error: expect.any(String),
        name,
        url: expect.any(String),
      }),
    );
  });

  it('POST /api/v1/catalog/:name returns create not implemented', async () => {
    const { status, body } = await json('/api/v1/catalog/unused', { method: 'POST' });
    expect(status).toBe(500);
    expect(body.error).toBe('create not implemented');
  });

  it('DELETE /api/v1/catalog/:name returns delete not implemented', async () => {
    const { status, body } = await json('/api/v1/catalog/unused', { method: 'DELETE' });
    expect(status).toBe(500);
    expect(body.error).toBe('delete not implemented');
  });

  it('POST install from unknown catalog returns 404', async () => {
    const catalog = uniqueId('no_catalog');
    const { status, body } = await json(
      `/api/v1/catalog/${catalog}/install/someproject`,
      { method: 'POST' },
    );
    expect(status).toBe(404);
    expect(body.error).toBe('unable to find script catalog');
  });

  it('POST update of unknown catalog returns 404', async () => {
    const name = uniqueId('no_catalog_update');
    const { status, body } = await json(`/api/v1/catalog/${name}/update`, {
      method: 'POST',
    });
    expect(status).toBe(404);
    expect(body).toEqual(
      expect.objectContaining({
        error: expect.any(String),
        name,
        url: expect.any(String),
      }),
    );
  });
});
