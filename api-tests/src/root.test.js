import { beforeAll, describe, expect, it } from 'vitest';
import { assertServerReachable } from './helpers.js';
import { json, request } from './client.js';

describe('root and api info', () => {
  beforeAll(async () => {
    await assertServerReachable();
  });

  it('GET / redirects to /maiden', async () => {
    const { response, status } = await request('/', { redirect: 'manual' });
    expect(status).toBe(302);
    const location = response.headers.get('location');
    expect(location).toMatch(/\/maiden$/);
  });

  it('GET /api/v1 returns api name and version', async () => {
    const { status, body } = await json('/api/v1');
    expect(status).toBe(200);
    expect(body).toEqual(
      expect.objectContaining({
        api: 'maiden',
        version: expect.any(String),
      }),
    );
    expect(body.version.length).toBeGreaterThan(0);
  });
});
