import parsePath from 'parse-filepath';

const API_ROOT = '/api/v1';

function apiPath(p) {
  return `${API_ROOT}/${p}`;
}

export const DUST_CODE_RESOURCE = apiPath('dust/code');
export const DUST_AUDIO_RESOURCE = apiPath('dust/audio');
export const DUST_DATA_RESOURCE = apiPath('dust/data');
export const DUST_SOURCES_RESOURCE = apiPath('dust/data/sources');
export const DUST_CATALOGS_RESOURCE = apiPath('dust/data/catalogs');

export const DUST_PROTECTED_RESOURCES = new Set([
  DUST_AUDIO_RESOURCE,
  DUST_CODE_RESOURCE,
  DUST_DATA_RESOURCE,
  DUST_SOURCES_RESOURCE,
  DUST_CATALOGS_RESOURCE,
]);

export const isProtectedResource = resource => DUST_PROTECTED_RESOURCES.has(resource);

class API {
  static siblingResourceForName(name, siblingResource, category = 'scripts') {
    let resourceBase = apiPath(`${category}/`);
    if (siblingResource) {
      // FIXME: this assumes siblingResource is absolute and lacks an authority
      resourceBase = `${parsePath(siblingResource).dirname}/`;
    }
    return resourceBase + encodeURI(name);
  }

  static childResourceForName(name, parentResource) {
    return `${parentResource}/${encodeURI(name)}`;
  }

  static listRoot(resourceRoot, cb) {
    fetch(apiPath(resourceRoot)).then(cb);
  }

  // https://stackoverflow.com/questions/40284338/react-fetch-delete-and-put-requests
  static writeTextResource(resource, code, cb) {
    const formData = new FormData();
    const codeBlob = new Blob([code], { type: 'text/utf-8' });
    formData.append('value', codeBlob);
    fetch(resource, {
      method: 'PUT',
      body: formData,
    }).then(cb);
  }

  static writeJSONResource(resource, code, cb) {
    const formData = new FormData();
    const codeBlob = new Blob([JSON.stringify(code)], { type: 'application/json' });
    formData.append('value', codeBlob);
    fetch(resource, {
      method: 'PUT',
      body: formData,
    }).then(cb);
  }

  static getResource(resource, cb) {
    fetch(resource, {
      method: 'GET',
    }).then(cb);
  }

  static deleteResource(resource, cb) {
    fetch(resource, {
      method: 'DELETE',
    }).then(cb);
  }

  static renameResource(resource, name, cb) {
    const formData = new FormData();
    formData.append('name', name);
    fetch(resource, {
      method: 'PATCH',
      body: formData,
    }).then(cb);
  }

  static createFolder(resource, cb) {
    const url = new URL(resource, document.location.origin);
    url.searchParams.append('kind', 'directory');
    fetch(url, {
      method: 'PUT',
    }).then(cb);
  }

  static getReplEndpoints(cb) {
    const origin = document.location.hostname;
    fetch('repl-endpoints.json').then(response => {
      response.json().then(data => {
        // this is ugly; if hostname is missing from the ws urls for the repls
        // insert the hostname of this document
        const config = new Map();
        const template = new Map(Object.entries(data));
        template.forEach((value, key) => {
          const url = new URL(value);
          if (url.hostname === undefined || url.hostname === 'maiden_app_location') {
            url.hostname = origin;
          }
          config.set(key, url.href);
        });
        cb(config);
      });
    });
  }

  static getUnitMapping(cb) {
    fetch('units.json').then(response => {
      response.json().then(data => {
        cb(new Map(Object.entries(data.units)));
      });
    });
  }

  static doUnitOperation(unit, operation, cb) {
    const url = `${API_ROOT}/unit/${unit}?do=${operation}`;
    fetch(url).then(response => {
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static resourceForScript(name, path) {
    // TODO: would be good to clean up and normalize urls
    if (path) {
      return apiPath(`${path}/${name}`);
    }
    return apiPath(name);
  }

  static fileFromResource(resource) {
    // MAINT: this totally breaks the encapsulation of script resources and
    // returns what norns (matron) would see as the script path
    const prefix = apiPath('dust/');
    return resource.split(prefix)[1];
  }

  static categoryFromResource(resource) {
    // MAINT: another case of broken encapsulation, explorer sections/category
    // tool actions need to ensure the only operate on stuff in their section
    // but the global selection (activeBuffer) is just a URL. here we do evil
    // stuff like extract information out of the URL
    const tail = resource.split(API_ROOT)[1];
    return tail.split('/')[1];
  }

  static editorConfigResource() {
    return API.resourceForScript('editor.json', 'dust/data');
  }

  static getCatalogSummary(onSuccess, onFailure) {
    const url = `${API_ROOT}/catalogs`;
    fetch(url).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static getCatalogByURL(catalogURL, onSuccess, onFailure) {
    fetch(catalogURL).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static getCatalog(catalogName, onSuccess, onFailure) {
    const name = encodeURIComponent(catalogName);
    const url = `${API_ROOT}/catalog/${name}`;
    fetch(url).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static updateCatalog(catalogURL, onSuccess, onFailure) {
    const url = `${catalogURL}/update`;
    fetch(url, { method: 'POST' }).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static getProjectSummary(onSuccess, onFailure) {
    const url = `${API_ROOT}/projects`;
    fetch(url).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static getProject(projectName, onSuccess, onFailure) {
    const name = encodeURIComponent(projectName);
    const url = `${API_ROOT}/project/${name}`;
    fetch(url).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static installProject(catalogURL, name, onSuccess, onFailure) {
    const encodedName = encodeURIComponent(name);
    const url = `${catalogURL}/install/${encodedName}`;
    fetch(url, { method: 'POST' }).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static installProjectFromURL(sourceURL, onSuccess, onFailure) {
    const encodedURL = encodeURIComponent(sourceURL);
    const url = `${API_ROOT}/project/install?url=${encodedURL}`;
    fetch(url, { method: 'POST' }).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static updateProject(projectURL, onSuccess, onFailure) {
    // FIXME: this really shouldn't be a GET verb
    const url = `${projectURL}?update=`;
    return fetch(url, { method: 'GET' }).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }

  static removeProject(projectURL, onSuccess, onFailure) {
    fetch(projectURL, { method: 'DELETE' }).then(response => {
      const cb = response.ok ? onSuccess : onFailure;
      response.json().then(body => {
        cb(body);
      });
    });
  }
}

export default API;
