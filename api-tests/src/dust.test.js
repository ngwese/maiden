import { describe, expect, it } from 'vitest';
import { formWithName, formWithValue, json, request } from './client.js';
import { ensureDir, useWorkspace, writeFile } from './helpers.js';

describe('dust api', () => {
  const ws = useWorkspace();

  describe('read', () => {
    it('GET /api/v1/dust lists the dust root', async () => {
      const { status, body } = await json('/api/v1/dust');
      expect(status).toBe(200);
      expect(body.path).toBe('');
      expect(body.url).toBe('/api/v1/dust');
      expect(Array.isArray(body.entries)).toBe(true);

      for (const entry of body.entries) {
        expect(entry).toEqual(
          expect.objectContaining({
            name: expect.any(String),
            url: expect.any(String),
          }),
        );
        expect(entry.name.startsWith('.')).toBe(false);
        if (Object.prototype.hasOwnProperty.call(entry, 'children')) {
          expect(entry.children).toEqual([]);
        }
      }
    });

    it('GET of a missing path returns 404 with error', async () => {
      const missing = ws.path('does-not-exist-' + Date.now());
      const { status, body } = await json(`/api/v1/dust/${missing}`);
      expect(status).toBe(404);
      expect(body).toEqual(expect.objectContaining({ error: expect.any(String) }));
    });
  });

  describe('write', () => {
    it('PUT ?kind=directory creates a directory', async () => {
      const dir = ws.path('new-dir');
      const { status, body } = await json(`/api/v1/dust/${dir}?kind=directory`, {
        method: 'PUT',
      });
      expect(status).toBe(200);
      expect(body.message).toContain('created directory');

      const listing = await json(`/api/v1/dust/${dir}`);
      expect(listing.status).toBe(200);
      expect(listing.body.path).toContain('new-dir');
      expect(Array.isArray(listing.body.entries)).toBe(true);
    });

    it('PUT with multipart value uploads a file', async () => {
      const file = ws.path('hello.txt');
      const content = 'hello maiden\n';
      const { status, body } = await request(`/api/v1/dust/${file}`, {
        method: 'PUT',
        body: formWithValue(content, 'hello.txt'),
      });
      expect(status).toBe(200);
      expect(body.message).toContain('uploaded');

      const got = await request(`/api/v1/dust/${file}`);
      expect(got.status).toBe(200);
      expect(got.body).toBe(content);
    });

    it('PUT with neither kind nor value returns 400', async () => {
      const file = ws.path('missing-value.txt');
      const { status, body } = await json(`/api/v1/dust/${file}`, { method: 'PUT' });
      expect(status).toBe(400);
      expect(body).toEqual(expect.objectContaining({ error: expect.any(String) }));
    });

    it('GET of .sc and .scd forces text/plain charset utf-8', async () => {
      const sc = ws.path('engine.sc');
      const scd = ws.path('synth.scd');
      await writeFile(sc, '// supercollider\n', 'engine.sc');
      await writeFile(scd, '// scd\n', 'synth.scd');

      for (const path of [sc, scd]) {
        const { status, headers, body } = await request(`/api/v1/dust/${path}`);
        expect(status).toBe(200);
        expect(headers.get('content-type')).toBe('text/plain; charset=utf-8');
        expect(typeof body).toBe('string');
      }
    });

    it('omits names starting with . from directory listings', async () => {
      const dir = ws.path('hidden-parent');
      await ensureDir(dir);
      await writeFile(`${dir}/.secret`, 'nope\n', '.secret');
      await writeFile(`${dir}/visible.txt`, 'yes\n', 'visible.txt');

      const { status, body } = await json(`/api/v1/dust/${dir}`);
      expect(status).toBe(200);
      const names = body.entries.map(e => e.name);
      expect(names).toContain('visible.txt');
      expect(names.some(n => n.startsWith('.'))).toBe(false);
    });
  });

  describe('rename and delete', () => {
    it('PATCH renames and returns the new url', async () => {
      const original = ws.path('before.txt');
      await writeFile(original, 'rename me\n', 'before.txt');

      const { status, body } = await request(`/api/v1/dust/${original}`, {
        method: 'PATCH',
        body: formWithName('after.txt'),
      });
      expect(status).toBe(200);
      expect(body.url).toMatch(/after\.txt$/);

      const missing = await json(`/api/v1/dust/${original}`);
      expect(missing.status).toBe(404);

      const renamed = ws.path('after.txt');
      const got = await request(`/api/v1/dust/${renamed}`);
      expect(got.status).toBe(200);
      expect(got.body).toBe('rename me\n');
    });

    it('PATCH without name returns 400', async () => {
      const file = ws.path('needs-name.txt');
      await writeFile(file, 'x\n', 'needs-name.txt');
      const { status, body } = await request(`/api/v1/dust/${file}`, {
        method: 'PATCH',
        body: new FormData(),
      });
      expect(status).toBe(400);
      expect(body.error).toBe("missing 'name' key in form");
    });

    it('PATCH of a missing path returns 404', async () => {
      const missing = ws.path('gone-before-rename.txt');
      const { status, body } = await request(`/api/v1/dust/${missing}`, {
        method: 'PATCH',
        body: formWithName('whatever.txt'),
      });
      expect(status).toBe(404);
      expect(body).toEqual(expect.objectContaining({ error: expect.any(String) }));
    });

    it('DELETE removes a path', async () => {
      const file = ws.path('to-delete.txt');
      await writeFile(file, 'bye\n', 'to-delete.txt');

      const { status, body } = await json(`/api/v1/dust/${file}`, { method: 'DELETE' });
      expect(status).toBe(200);
      expect(body.message).toContain('deleted');

      const gone = await json(`/api/v1/dust/${file}`);
      expect(gone.status).toBe(404);
    });

    it('DELETE of a missing path returns 404', async () => {
      const missing = ws.path('already-gone.txt');
      const { status, body } = await json(`/api/v1/dust/${missing}`, { method: 'DELETE' });
      expect(status).toBe(404);
      expect(body).toEqual(expect.objectContaining({ error: expect.any(String) }));
    });
  });
});
