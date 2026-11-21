import { afterAll, beforeAll, expect } from 'vitest';
import { baseURL, formWithValue, json, request } from './client.js';

export const TEST_ROOT = 'code/__maiden_api_tests__';

export function uniqueId(prefix = 't') {
  return `${prefix}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

export async function assertServerReachable() {
  try {
    const { status, body } = await json('/api/v1');
    expect(status).toBe(200);
    expect(body.api).toBe('maiden');
  } catch (err) {
    throw new Error(
      `maiden server not reachable at ${baseURL()} (set MAIDEN_BASE_URL). ${err.message}`,
    );
  }
}

export async function ensureDir(relativePath) {
  const { status, body } = await json(`/api/v1/dust/${relativePath}?kind=directory`, {
    method: 'PUT',
  });
  expect(status).toBe(200);
  expect(body.message).toContain('created directory');
  return relativePath;
}

export async function writeFile(relativePath, content, filename = 'value.txt') {
  const { status, body } = await request(`/api/v1/dust/${relativePath}`, {
    method: 'PUT',
    body: formWithValue(content, filename),
  });
  expect(status).toBe(200);
  expect(body.message).toContain('uploaded');
  return relativePath;
}

export async function deletePath(relativePath) {
  const { status } = await json(`/api/v1/dust/${relativePath}`, { method: 'DELETE' });
  return status;
}

/**
 * Creates an isolated workspace under code/__maiden_api_tests__/<id>/ and
 * removes it after the suite finishes.
 */
export function useWorkspace() {
  const id = uniqueId('suite');
  const root = `${TEST_ROOT}/${id}`;

  beforeAll(async () => {
    await assertServerReachable();
    await ensureDir(TEST_ROOT);
    await ensureDir(root);
  });

  afterAll(async () => {
    await deletePath(root);
  });

  return {
    id,
    root,
    path: (...parts) => [root, ...parts].join('/'),
  };
}
