import api, { readLastModified } from './api';

describe('siblingResourceForName', () => {
  it('no sibling returns something', () => {
    const r = api.siblingResourceForName('untitled.lua');
    expect(r).toEqual('/api/v1/scripts/untitled.lua');
  });

  it('should escape filename', () => {
    const r = api.siblingResourceForName('one two.lua');
    expect(r).toEqual('/api/v1/scripts/one%20two.lua');
  });

  it('root sibling should match no sibling', () => {
    const r = api.siblingResourceForName('untitled.lua');
    const q = api.siblingResourceForName('untitled.lua', '/api/v1/scripts/foo.lua');
    expect(q).toEqual(r);
  });

  it('non-root sibling works', () => {
    const r = api.siblingResourceForName('foo.lua', '/api/v1/scripts/one/two/three.lua');
    expect(r).toEqual('/api/v1/scripts/one/two/foo.lua');
  });
});

describe('readLastModified', () => {
  const headers = value => ({
    get: name => (name.toLowerCase() === 'last-modified' ? value : null),
  });

  it('returns null when missing', () => {
    expect(readLastModified(headers(null))).toBeNull();
  });

  it('returns a single HTTP-date', () => {
    const lm = 'Sun, 06 Nov 1994 08:49:37 GMT';
    expect(readLastModified(headers(lm))).toBe(lm);
  });

  it('prefers the last date when fetch joins duplicates', () => {
    const first = 'Sun, 06 Nov 1994 08:49:37 GMT';
    const second = 'Mon, 07 Nov 1994 09:00:00 GMT';
    expect(readLastModified(headers(`${first}, ${second}`))).toBe(second);
  });
});

describe('fileFromResource', () => {
  it('extracts basic path', () => {
    const r = api.fileFromResource('/api/v1/dust/one/two.lua');
    expect(r).toEqual('one/two.lua');
  });

  it('returns undefined when prefix does not match', () => {
    const r = api.fileFromResource('/api/v1/notdust/something-else.lua');
    expect(r).toBeUndefined();
  });
});
