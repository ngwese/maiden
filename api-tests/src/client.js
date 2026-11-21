export function baseURL() {
  return process.env.MAIDEN_BASE_URL || 'http://127.0.0.1:5000';
}

export function url(path) {
  const root = baseURL().replace(/\/$/, '');
  const suffix = path.startsWith('/') ? path : `/${path}`;
  return `${root}${suffix}`;
}

export async function request(path, options = {}) {
  const response = await fetch(url(path), options);
  const contentType = response.headers.get('content-type') || '';
  let body = null;
  if (contentType.includes('application/json')) {
    body = await response.json();
  } else {
    body = await response.text();
  }
  return { response, body, status: response.status, headers: response.headers };
}

export async function json(path, options = {}) {
  return request(path, options);
}

export function formWithValue(content, filename = 'value', type = 'text/plain') {
  const form = new FormData();
  form.append('value', new Blob([content], { type }), filename);
  return form;
}

export function formWithName(name) {
  const form = new FormData();
  form.append('name', name);
  return form;
}
