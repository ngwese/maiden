import { beforeAll, describe, expect, it } from 'vitest';
import { assertServerReachable } from './helpers.js';
import { json } from './client.js';

describe('unit api', () => {
  beforeAll(async () => {
    await assertServerReachable();
  });

  it('GET /api/v1/unit/<unused>.service returns 404 with dbus or 503 without', async () => {
    const { status, body } = await json('/api/v1/unit/maiden-api-tests-unused.service');
    expect([404, 503]).toContain(status);
    expect(body).toEqual(expect.objectContaining({ error: expect.any(String) }));
    if (status === 503) {
      expect(body.error).toBe('no dbus connection');
    } else {
      expect(body.error).toContain('unknown unit');
    }
  });

  it('GET with unrecognized do returns 503 without dbus or 400 with dbus', async () => {
    const { status, body } = await json(
      '/api/v1/unit/maiden-api-tests-unused.service?do=nope',
    );
    expect([400, 503]).toContain(status);
    expect(body).toEqual(expect.objectContaining({ error: expect.any(String) }));
    if (status === 503) {
      expect(body.error).toBe('no dbus connection');
    } else {
      expect(body.error).toBe('unrecognized operation');
    }
  });
});
