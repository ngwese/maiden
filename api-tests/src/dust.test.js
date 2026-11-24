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
      // Editor only renders text when Content-Type contains "text" or "application/json".
      expect(got.headers.get('content-type') || '').toMatch(/text|application\/json/i);
    });

    it('GET of .lua uses a text Content-Type', async () => {
      const file = ws.path('script.lua');
      await writeFile(file, 'print("hi")\n', 'script.lua');
      const { status, headers, body } = await request(`/api/v1/dust/${file}`);
      expect(status).toBe(200);
      expect(body).toBe('print("hi")\n');
      expect(headers.get('content-type') || '').toMatch(/text/i);
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

    it('GET and DELETE work for filenames with #', async () => {
      const dir = ws.path('hash-parent');
      await ensureDir(dir);
      const encoded = `${dir}/${encodeURIComponent('#awake.lua#')}`;
      const content = '-- emacs autosave\n';
      await writeFile(encoded, content, '#awake.lua#');

      const listing = await json(`/api/v1/dust/${dir}`);
      expect(listing.status).toBe(200);
      const entry = listing.body.entries.find(e => e.name === '#awake.lua#');
      expect(entry).toBeTruthy();
      expect(entry.url).toMatch(/%23awake\.lua%23$/);

      const got = await request(`/api/v1/dust/${encoded}`);
      expect(got.status).toBe(200);
      expect(got.body).toBe(content);

      const deleted = await json(`/api/v1/dust/${encoded}`, { method: 'DELETE' });
      expect(deleted.status).toBe(200);

      const gone = await json(`/api/v1/dust/${encoded}`);
      expect(gone.status).toBe(404);
    });
  });

  describe('Last-Modified and HEAD', () => {
    const httpDate = /^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/;

    it('GET file and directory include Last-Modified', async () => {
      const dir = ws.path('lm-dir');
      await ensureDir(dir);
      const file = `${dir}/note.txt`;
      await writeFile(file, 'stamp\n', 'note.txt');

      const fileGet = await request(`/api/v1/dust/${file}`);
      expect(fileGet.status).toBe(200);
      expect(fileGet.headers.get('last-modified') || '').toMatch(httpDate);

      const dirGet = await request(`/api/v1/dust/${dir}`);
      expect(dirGet.status).toBe(200);
      expect(dirGet.headers.get('last-modified') || '').toMatch(httpDate);

      const rootGet = await request('/api/v1/dust');
      expect(rootGet.status).toBe(200);
      expect(rootGet.headers.get('last-modified') || '').toMatch(httpDate);
    });

    it('HEAD file and directory return Last-Modified matching GET with no body', async () => {
      const dir = ws.path('head-dir');
      await ensureDir(dir);
      const file = `${dir}/head.txt`;
      await writeFile(file, 'head me\n', 'head.txt');

      for (const path of [`/api/v1/dust/${file}`, `/api/v1/dust/${dir}`]) {
        const got = await request(path);
        const head = await request(path, { method: 'HEAD' });
        expect(head.status).toBe(200);
        expect(head.body).toBe('');
        expect(head.headers.get('last-modified')).toBe(got.headers.get('last-modified'));
      }
    });

    it('HEAD of a missing path returns 404', async () => {
      const missing = ws.path('head-missing.txt');
      const { status, body } = await request(`/api/v1/dust/${missing}`, { method: 'HEAD' });
      expect(status).toBe(404);
      expect(body).toBe('');
    });

    it('external write changes Last-Modified on HEAD', async () => {
      const file = ws.path('mtime-change.txt');
      await writeFile(file, 'v1\n', 'mtime-change.txt');
      const before = await request(`/api/v1/dust/${file}`, { method: 'HEAD' });
      const lmBefore = before.headers.get('last-modified');
      expect(lmBefore).toMatch(httpDate);

      await new Promise(r => setTimeout(r, 1100));
      await writeFile(file, 'v2\n', 'mtime-change.txt');

      const after = await request(`/api/v1/dust/${file}`, { method: 'HEAD' });
      expect(after.headers.get('last-modified')).not.toBe(lmBefore);
    });

    it('PUT response includes Last-Modified', async () => {
      const file = ws.path('put-lm.txt');
      const { status, headers, body } = await request(`/api/v1/dust/${file}`, {
        method: 'PUT',
        body: formWithValue('upload\n', 'put-lm.txt'),
      });
      expect(status).toBe(200);
      expect(body.message).toContain('uploaded');
      expect(headers.get('last-modified') || '').toMatch(httpDate);
    });
  });

  describe('conditional PUT', () => {
    it('PUT with matching If-Unmodified-Since succeeds', async () => {
      const file = ws.path('cond-ok.txt');
      await writeFile(file, 'original\n', 'cond-ok.txt');
      const head = await request(`/api/v1/dust/${file}`, { method: 'HEAD' });
      const lm = head.headers.get('last-modified');

      const { status, body } = await request(`/api/v1/dust/${file}`, {
        method: 'PUT',
        headers: { 'If-Unmodified-Since': lm },
        body: formWithValue('updated\n', 'cond-ok.txt'),
      });
      expect(status).toBe(200);
      expect(body.message).toContain('uploaded');

      const got = await request(`/api/v1/dust/${file}`);
      expect(got.body).toBe('updated\n');
    });

    it('PUT with stale If-Unmodified-Since returns 412 and leaves body unchanged', async () => {
      const file = ws.path('cond-412.txt');
      await writeFile(file, 'keep-me\n', 'cond-412.txt');
      const head = await request(`/api/v1/dust/${file}`, { method: 'HEAD' });
      const lm = head.headers.get('last-modified');

      await new Promise(r => setTimeout(r, 1100));
      await writeFile(file, 'device-changed\n', 'cond-412.txt');

      const conflict = await request(`/api/v1/dust/${file}`, {
        method: 'PUT',
        headers: { 'If-Unmodified-Since': lm },
        body: formWithValue('browser-overwrite\n', 'cond-412.txt'),
      });
      expect(conflict.status).toBe(412);
      expect(conflict.body).toEqual(expect.objectContaining({ error: expect.any(String) }));

      const got = await request(`/api/v1/dust/${file}`);
      expect(got.body).toBe('device-changed\n');

      const forced = await request(`/api/v1/dust/${file}`, {
        method: 'PUT',
        body: formWithValue('forced\n', 'cond-412.txt'),
      });
      expect(forced.status).toBe(200);
      const afterForce = await request(`/api/v1/dust/${file}`);
      expect(afterForce.body).toBe('forced\n');
    });
  });
});
